#!/bin/bash

# ===============================================================
# EUserv 自动续期一键部署脚本 V2.1 - 离线集成版 (终极完全体)
# 新增：基于本地状态文件的智能跳过逻辑。续期成功后会记录 EUserv 返回的
# 真实"可续期日期"，在该日期之前的每日定时任务会直接跳过（不登录、不触发
# 验证码/邮箱PIN、不发送TG通知），避免每天空跑消耗接码/验证码额度。
# ===============================================================
# wget -O EUserv.sh https://raw.githubusercontent.com/SuzukiRenz/ScriptHub/refs/heads/main/SH/EUserv.sh && chmod +x EUserv.sh && ./EUserv.sh
# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# 配置文件路径
INSTALL_DIR="/opt/euserv_renew"
CONFIG_FILE="${INSTALL_DIR}/config.env"
SERVICE_NAME="euserv-renew"
COMMAND_LINK="/usr/local/bin/dj"

print_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
print_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
print_error() { echo -e "${RED}[ERROR]${NC} $1"; }

check_root() {
    if [[ $EUID -ne 0 ]]; then
        print_error "此脚本必须以root权限运行"
        exit 1
    fi
}

create_directories() {
    print_info "创建项目目录..."
    mkdir -p ${INSTALL_DIR}/{logs,config}
}

# ---------------------------------------------------------
# 核心：生成内嵌文件
# ---------------------------------------------------------
generate_local_files() {
    print_info "正在生成内嵌 Python 脚本与依赖清单..."

    cat > ${INSTALL_DIR}/requirements.txt <<'EOF'
pytesseract
Pillow==12.1.0
requests==2.32.5
beautifulsoup4==4.14.3
lxml==6.0.2
imap-tools
python-dotenv
EOF

    # 必须使用单引号括起 PYTHON_EOF，防止变量逃逸
    cat > ${INSTALL_DIR}/euser_renew.py <<'PYTHON_EOF'
#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
EUserv 自动续期脚本 - 多账号多线程版本 (终极完全体)
"""
import os
import sys
import io
import re
import json
import time
import threading
import subprocess
import logging
from typing import Dict, List, Tuple, Optional
from datetime import datetime
from concurrent.futures import ThreadPoolExecutor, as_completed

from PIL import Image, ImageEnhance, ImageFilter, ImageOps
import pytesseract
import requests
from bs4 import BeautifulSoup
from imap_tools import MailBox, AND
from urllib.parse import quote

logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s [%(threadName)s] %(levelname)s: %(message)s',
    datefmt='%Y-%m-%d %H:%M:%S'
)
logger = logging.getLogger(__name__)

if not hasattr(Image, 'ANTIALIAS'):
    Image.ANTIALIAS = Image.Resampling.LANCZOS


USER_AGENT = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/94.0.4606.61 Safari/537.36"

# 本地状态文件：记录每个账号/订单最近一次查询到的"可续期日期"。
# 只要该日期还没到，就跳过整次执行（不登录、不触发验证码/邮箱PIN），
# 从而避免在续期窗口未到时的无意义每日执行。
STATE_FILE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "renew_state.json")

class AccountConfig:
    def __init__(self, email, password, imap_server='imap.gmail.com', email_password=''):
        self.email = email
        self.password = password
        self.imap_server = imap_server
        self.email_password = email_password if email_password else password

class GlobalConfig:
    def __init__(self, telegram_bot_token="", telegram_chat_id="", bark_url="", max_workers=3, max_login_retries=3):
        self.telegram_bot_token = telegram_bot_token
        self.telegram_chat_id = telegram_chat_id
        self.bark_url = bark_url
        self.max_workers = max_workers
        self.max_login_retries = max_login_retries

GLOBAL_CONFIG = GlobalConfig(
    telegram_bot_token=os.getenv("TG_BOT_TOKEN"),
    telegram_chat_id=os.getenv("TG_CHAT_ID"),
    bark_url=os.getenv("BARK_URL"),
    max_workers=3,
    max_login_retries=5
)

ACCOUNTS = [
    AccountConfig(
        email=os.getenv("EUSERV_EMAIL"),
        password=os.getenv("EUSERV_PASSWORD"),
        imap_server="imap.gmail.com",
        email_password=os.getenv("EMAIL_PASS")
    ),
]

def recognize_and_calculate(captcha_image_url: str, session: requests.Session) -> Optional[str]:
    """使用 pytesseract 识别验证码（数学运算或字符串），带多策略预处理和投票。"""
    DIGIT_CORRECTIONS = {'O': '0', 'o': '0', 'D': '0', 'Q': '0', 'I': '1', 'i': '1', 'l': '1', '|': '1', '!': '1', 'Z': '2', 'z': '2', 'S': '5', 's': '5', 'G': '6', 'b': '6', 'B': '8', 'g': '8'}
    OPERATOR_CORRECTIONS = {'x': '×', 'X': '×', '*': '×', '×': '×', '÷': '/', ':': '/', '+': '+', '-': '-', '—': '-', '–': '-', '/': '/'}

    def fix_digit(c):
        if c.isdigit(): return c
        return DIGIT_CORRECTIONS.get(c, DIGIT_CORRECTIONS.get(c.upper(), c))

    def clean_text(text: str) -> str:
        text = text.replace(' ', '').replace('\n', '').replace('\r', '').replace('=', '')
        text = re.sub(r'[^0-9A-Za-z+\-*/×÷:|!]', '', text)
        return text

    def parse_candidate(raw: str) -> Optional[str]:
        raw = clean_text(raw)
        if not raw:
            return None

        # 优先解析数学验证码。支持 7+3、7x3、7/3 等，也兼容 OCR 多识别一个字符的情况。
        m = re.search(r'([0-9OoDQIl|!ZzSsGgbB])([+\-xX*×÷/:])([0-9OoDQIl|!ZzSsGgbB])', raw)
        if m:
            left_c = fix_digit(m.group(1))
            op_c = OPERATOR_CORRECTIONS.get(m.group(2), m.group(2))
            right_c = fix_digit(m.group(3))
            try:
                result = calculate_operation(int(left_c), op_c, int(right_c), raw)
                if result is not None:
                    return result
            except (ValueError, IndexError):
                pass

        # 如果 OCR 只识别出纯数字，且长度合理，直接返回。
        normalized = ''.join(fix_digit(c) for c in raw)
        if normalized.isdigit() and 1 <= len(normalized) <= 6:
            return normalized

        # 纯字符串验证码兜底。
        if len(raw) >= 6:
            return raw.upper()
        return None

    def green_mask(src: Image.Image, mode: str) -> Image.Image:
        img = src.convert('RGB')
        pixels = img.load()
        width, height = img.size
        for x in range(width):
            for y in range(height):
                r, g, b = pixels[x, y]
                if mode == 'green_strict':
                    keep = (r > 170 and 80 < g < 235 and b < 120 and r > g + 20 and r > b + 80)
                elif mode == 'green_loose':
                    keep = (r > 140 and g > 60 and b < 160 and r > b + 45)
                else:
                    keep = True
                pixels[x, y] = (0, 0, 0) if keep else (255, 255, 255)
        return img

    def preprocess_variants(src: Image.Image) -> List[Image.Image]:
        variants = []
        base_variants = [green_mask(src, 'green_strict'), green_mask(src, 'green_loose'), src.convert('RGB')]
        for base in base_variants:
            gray = ImageOps.grayscale(base)
            gray = ImageEnhance.Contrast(gray).enhance(2.5)
            gray = gray.filter(ImageFilter.MedianFilter(size=3))
            for scale in (3, 4, 5):
                enlarged = gray.resize((gray.width * scale, gray.height * scale), Image.Resampling.LANCZOS)
                for threshold in (120, 150, 180, 205):
                    bw = enlarged.point(lambda v, t=threshold: 0 if v < t else 255, 'L')
                    variants.append(bw)
                    variants.append(ImageOps.invert(bw))
        return variants

    try:
        response = session.get(captcha_image_url, timeout=15)
        response.raise_for_status()
        src = Image.open(io.BytesIO(response.content)).convert('RGB')

        candidates: List[str] = []
        configs = [
            r'--oem 1 --psm 7 -c tessedit_char_whitelist=0123456789+-×÷xX*/:=OoDQIl|!ZzSsGgbB',
            r'--oem 1 --psm 8 -c tessedit_char_whitelist=0123456789+-×÷xX*/:=OoDQIl|!ZzSsGgbB',
            r'--oem 1 --psm 13 -c tessedit_char_whitelist=0123456789+-×÷xX*/:=OoDQIl|!ZzSsGgbB',
        ]

        for img in preprocess_variants(src):
            for cfg in configs:
                raw = pytesseract.image_to_string(img, config=cfg).strip()
                parsed = parse_candidate(raw)
                if parsed:
                    candidates.append(parsed)

        if not candidates:
            logger.warning("验证码 OCR 未产生有效候选")
            return None

        # 多预处理结果投票。平票时取最短数字结果，降低把噪声当字符串提交的概率。
        counts = {}
        for c in candidates:
            counts[c] = counts.get(c, 0) + 1
        best = sorted(counts.items(), key=lambda kv: (-kv[1], len(kv[0]), kv[0]))[0][0]
        logger.info(f"验证码候选: {counts}，采用: {best}")
        return best
    except Exception as e:
        logger.error(f"验证码异常: {e}")
        return None

def calculate_operation(left, op, right, raw_text, silent=False):
    try:
        if op == '+': result = left + right
        elif op == '-': result = left - right
        elif op in {'×', '*', 'x', 'X'}: result = left * right
        elif op in {'/', '÷', ':'}: result = left // right if right != 0 else None
        else: return None
        return str(result)
    except: return None

def get_euserv_pin(email, email_password, imap_server):
    try:
        with MailBox(imap_server).login(email, email_password) as mailbox:
            for msg in mailbox.fetch(AND(from_='no-reply@euserv.com', body='PIN'), limit=1, reverse=True):
                match = re.search(r'PIN:\s*\n?(\d{6})', msg.text)
                if match: return match.group(1)
                match_fallback = re.search(r'(\d{6})', msg.text)
                if match_fallback: return match_fallback.group(1)
        return None
    except Exception as e:
        logger.error(f"PIN异常: {e}")
        return None

class EUserv:
    def __init__(self, config):
        self.config = config
        self.session = requests.Session()
        self.sess_id = None
        self.c_id = None

    def login(self) -> bool:
        logger.info(f"正在登录账号: {self.config.email}")
        headers = {'user-agent': USER_AGENT, 'origin': 'https://www.euserv.com'}
        url = "https://support.euserv.com/index.iphp"
        captcha_url = "https://support.euserv.com/securimage_show.php"
        
        try:
            sess = self.session.get(url, headers=headers)
            sid_match = re.search(r'sess_id["\']?\s*[:=]\s*["\']?([a-zA-Z0-9]{30,100})["\']?', sess.text)
            if not sid_match:
                sid_match = re.search(r'sess_id=([a-zA-Z0-9]{30,100})', sess.text)
            if not sid_match: return False
            sess_id = sid_match.group(1)
            
            self.session.get("https://support.euserv.com/pic/logo_small.png", headers=headers)
            
            login_data = {'email': self.config.email, 'password': self.config.password, 'form_selected_language': 'en', 'Submit': 'Login', 'subaction': 'login', 'sess_id': sess_id}
            response = self.session.post(url, headers=headers, data=login_data)
            
            soup = BeautifulSoup(response.text, "html.parser")

            if 'Please check email address' in response.text or 'kc2_login_iplock_cdown' in response.text:
                return False
            
            if 'captcha' in response.text.lower():
                logger.info("⚠️ 需要验证码，正在识别...")
                captcha_ok = False
                max_captcha_retries = int(os.getenv("CAPTCHA_MAX_RETRIES", "6"))
                retry_delay = int(os.getenv("CAPTCHA_RETRY_DELAY", "4"))
                for attempt in range(1, max_captcha_retries + 1):
                    if attempt > 1:
                        time.sleep(retry_delay)
                    # 给验证码 URL 加时间戳，避免缓存导致重复识别同一张失败图片。
                    captcha_fetch_url = f"{captcha_url}?t={int(time.time() * 1000)}&try={attempt}"
                    captcha_code = recognize_and_calculate(captcha_fetch_url, self.session)
                    if not captcha_code:
                        logger.warning(f"验证码第 {attempt}/{max_captcha_retries} 次识别失败，准备重试")
                        continue
                    logger.info(f"验证码第 {attempt}/{max_captcha_retries} 次提交候选: {captcha_code}")
                    captcha_data = {'subaction': 'login', 'sess_id': sess_id, 'captcha_code': captcha_code}
                    response = self.session.post(url, headers=headers, data=captcha_data)
                    if 'captcha' not in response.text.lower():
                        soup = BeautifulSoup(response.text, "html.parser")
                        captcha_ok = True
                        break
                    logger.warning(f"验证码第 {attempt}/{max_captcha_retries} 次被拒绝")
                if not captcha_ok:
                    logger.error(f"验证码识别达到上限 {max_captcha_retries} 次，停止本轮登录")
                    return False
            
            if 'PIN that you receive via email' in response.text:
                c_id_input = soup.find("input", {"name": "c_id"})
                if c_id_input: self.c_id = c_id_input["value"]
                time.sleep(3)
                pin = get_euserv_pin(self.config.email, self.config.email_password, self.config.imap_server)
                if not pin: return False
                confirm_data = {'pin': pin, 'sess_id': sess_id, 'Submit': 'Confirm', 'subaction': 'login', 'c_id': self.c_id}
                response = self.session.post(url, headers=headers, data=confirm_data)

            if any(chk in response.text for chk in ['Hello', 'Confirm or change your customer data here', 'logout']):
                self.sess_id = sess_id
                return True
            return False
        except Exception as e:
            logger.error(f"登录异常: {e}")
            return False

    def update_info(self):
        current_day = datetime.now().day
        if current_day not in [2, 22]:
            return

        logger.info(f"触发每月资料更新机制 (当前日期 {current_day} 号)...")
        try:
            url = f"https://support.euserv.com/index.iphp?sess_id={self.sess_id}&action=show_customerdata"
            headers = {'user-agent': USER_AGENT, 'host': 'support.euserv.com'}
            
            logger.info(f"进入用户界面...")
            response = self.session.get(url=url, headers=headers)
            response.raise_for_status()

            soup = BeautifulSoup(response.text, 'html.parser')

            if not self.c_id:
                self.c_id = soup.find("input", {"name": "c_id"})["value"]
                
            # 还原长达几十行的表单解析逻辑
            c_att = soup.select_one('#c_att option[selected]').get('value') if soup.select_one('#c_att option[selected]') else ''
            c_street = soup.find('input', {'name': 'c_street'})['value'] if soup.find('input', {'name': 'c_street'}) else ''
            c_streetno = soup.find('input', {'name': 'c_streetno'})['value'] if soup.find('input', {'name': 'c_streetno'}) else ''
            c_postal = soup.find('input', {'name': 'c_postal'})['value'] if soup.find('input', {'name': 'c_postal'}) else ''
            c_city = soup.find('input', {'name': 'c_city'})['value'] if soup.find('input', {'name': 'c_city'}) else ''
            c_country = soup.select_one('#c_country option[selected]').get('value') if soup.select_one('#c_country option[selected]') else ''
            c_phone_country_prefix = soup.find('input', {'name': 'c_phone_country_prefix'})['value'] if soup.find('input', {'name': 'c_phone_country_prefix'}) else ''      
            c_phone_password = soup.find('input', {'name': 'c_phone_password'})['value'] if soup.find('input', {'name': 'c_phone_password'}) else ''
            c_fax_country_prefix = soup.find('input', {'name': 'c_fax_country_prefix'})['value'] if soup.find('input', {'name': 'c_fax_country_prefix'}) else ''
            c_tac_date = soup.find('input', {'name': 'c_tac_date'})['value'] if soup.find('input', {'name': 'c_tac_date'}) else ''
            c_website = soup.find('input', {'name': 'c_website'})['value'] if soup.find('input', {'name': 'c_website'}) else ''
            c_firstcontact = soup.select_one('#c_firstcontact option[selected]').get('value') if soup.select_one('#c_firstcontact option[selected]') else ''
            c_emailabo_contract = soup.find('input', {'name': 'c_emailabo_contract'})['value'] if soup.find('input', {'name': 'c_emailabo_contract'}) else ''
            c_emailabo_products = soup.find('input', {'name': 'c_emailabo_products'})['value'] if soup.find('input', {'name': 'c_emailabo_products'}) else ''
            c_forumnick = soup.find('input', {'name': 'c_forumnick'})['value'] if soup.find('input', {'name': 'c_forumnick'}) else ''
            c_hrno = soup.find('input', {'name': 'c_hrno'})['value'] if soup.find('input', {'name': 'c_hrno'}) else ''
            c_hrcourt = soup.find('input', {'name': 'c_hrcourt'})['value'] if soup.find('input', {'name': 'c_hrcourt'}) else ''
            c_taxid = soup.find('input', {'name': 'c_taxid'})['value'] if soup.find('input', {'name': 'c_taxid'}) else ''
            c_identifier = soup.find('input', {'name': 'c_identifier'})['value'] if soup.find('input', {'name': 'c_identifier'}) else ''
            c_birthplace = soup.find('input', {'name': 'c_birthplace'})['value'] if soup.find('input', {'name': 'c_birthplace'}) else ''
            c_country_of_birth = soup.select_one('#c_country_of_birth option[selected]').get('value') if soup.select_one('#c_country_of_birth option[selected]') else ''

            c_birthdays = soup.find_all('input', {'name': 'c_birthday[]'})
            c_birthday_value = [b['value'].strip() if b else '' for b in c_birthdays]

            c_phones = soup.find_all('input', {'name': 'c_phone[]'})
            c_phone_value = [p['value'].strip() if p else '' for p in c_phones]

            c_faxs = soup.find_all('input', {'name': 'c_fax[]'})
            c_fax_value = [f['value'].strip() if f else '' for f in c_faxs]

            upInfo_data = {
                'sess_id': self.sess_id,
                'subaction': 'kc2_customer_data_update',
                'c_id': self.c_id,
                'c_org': '',
                'c_ustid[]': ['', ''],
                'c_att': c_att,
                'c_street': c_street,
                'c_streetno': c_streetno,
                'c_postal': c_postal,
                'c_city': c_city,
                'c_country': c_country,
                'c_birthday[]': c_birthday_value,
                'c_phone_country_prefix': c_phone_country_prefix,
                'c_phone[]': c_phone_value,
                'c_phone_password': c_phone_password,
                'c_fax_country_prefix': c_fax_country_prefix,
                'c_fax[]': c_fax_value,
                'c_tac_date': c_tac_date,
                'c_website': c_website,
                'c_firstcontact': c_firstcontact,
                'c_emailabo_contract': c_emailabo_contract,
                'c_emailabo_products': c_emailabo_products,
                'c_forumnick': c_forumnick,
                'c_hrno': c_hrno,
                'c_hrcourt': c_hrcourt,
                'c_taxid': c_taxid,
                'c_identifier': c_identifier,
                'c_birthplace': c_birthplace,
                'c_country_of_birth': c_country_of_birth
            }

            url = f"https://support.euserv.com/index.iphp"
            logger.info(f"提交保存用户信息...")
            response = self.session.post(url=url, headers=headers, data=upInfo_data)
            response.raise_for_status()

            if 'customer data has been changed' in response.text:
                logger.info(f"✅ 保存用户信息成功")
            else:
                logger.error(f"❌ 保存用户信息失败，接口返回response={response.text}")

        except Exception as e:
            logger.error(f"❌ 更新用户信息异常: {e}", exc_info=True)

    def get_servers(self) -> Dict[str, Tuple[bool, str]]:
        url = f"https://support.euserv.com/index.iphp?sess_id={self.sess_id}"
        headers = {'user-agent': USER_AGENT, 'origin': 'https://www.euserv.com'}
        try:
            resp = self.session.get(url=url, headers=headers)
            soup = BeautifulSoup(resp.text, 'html.parser')
            servers = {}
            selector = '#kc2_order_customer_orders_tab_content_1 .kc2_order_table.kc2_content_table tr, #kc2_order_customer_orders_tab_content_2 .kc2_order_table.kc2_content_table tr'
            for tr in soup.select(selector):
                server_id = tr.select('.td-z1-sp1-kc')
                if len(server_id) != 1: continue
                action_containers = tr.select('.td-z1-sp2-kc .kc2_order_action_container')
                if not action_containers: continue
                action_text = action_containers[0].get_text()
                can_renew = action_text.find("Contract extension possible from") == -1
                can_renew_date = ""
                if not can_renew:
                    match = re.search(r'\b\d{4}-\d{2}-\d{2}\b', action_text)
                    if match:
                        can_renew_date = match.group(0)
                        can_renew = datetime.today().date() >= datetime.strptime(can_renew_date, "%Y-%m-%d").date()
                servers[server_id[0].get_text().strip()] = (can_renew, can_renew_date)
            return servers
        except Exception as e:
            logger.error(f"获取服务器列表异常: {e}")
            return {}

    def renew_server(self, order_id: str) -> bool:
        logger.info(f"正在续期服务器 {order_id}...")
        url = "https://support.euserv.com/index.iphp"
        headers = {'user-agent': USER_AGENT, 'Host': 'support.euserv.com', 'origin': 'https://support.euserv.com'}
        try:
            data = {'Submit': 'Extend contract', 'sess_id': self.sess_id, 'ord_no': order_id, 'subaction': 'choose_order', 'show_contract_extension': '1', 'choose_order_subaction': 'show_contract_details'}
            self.session.post(url, headers=headers, data=data)
            
            data = {'sess_id': self.sess_id, 'subaction': 'show_kc2_security_password_dialog', 'prefix': 'kc2_customer_contract_details_extend_contract_', 'type': '1'}
            resp2 = self.session.post(url, headers=headers, data=data)
            if resp2.status_code != 200: return False
            
            time.sleep(8)
            pin = get_euserv_pin(self.config.email, self.config.email_password, self.config.imap_server)
            if not pin: return False
            
            data = {'sess_id': self.sess_id, 'auth': pin, 'subaction': 'kc2_security_password_get_token', 'prefix': 'kc2_customer_contract_details_extend_contract_', 'type': '1', 'ident': 'kc2_customer_contract_details_extend_contract_' + order_id}
            resp3 = self.session.post(url, headers=headers, data=data)
            result = json.loads(resp3.text)
            if result.get('rs') != 'success': return False
            
            token = result['token']['value']
            time.sleep(2)
            
            data = {'sess_id': self.sess_id, 'subaction': 'kc2_customer_contract_details_get_extend_contract_confirmation_dialog', 'token': token}
            self.session.post(url, headers=headers, data=data)

            data = {'sess_id': self.sess_id, 'ord_id': order_id, 'subaction': 'kc2_customer_contract_details_extend_contract_term', 'token': token}
            self.session.post(url, headers=headers, data=data)
            
            logger.info(f"✅ 服务器 {order_id} 续期成功")
            return True
        except Exception as e:
            logger.error(f"续期请求异常: {e}")
            return False

def send_telegram(message: str, config: GlobalConfig):
    if not config.telegram_bot_token or not config.telegram_chat_id: return
    url = f"https://api.telegram.org/bot{config.telegram_bot_token}/sendMessage"
    data = {"chat_id": config.telegram_chat_id, "text": message, "parse_mode": "HTML"}
    try:
        requests.post(url, json=data, timeout=10)
    except Exception as e: logger.error(f"TG通知异常: {e}")

def load_state() -> dict:
    """读取本地状态文件（记录每个账号各订单最近一次查到的可续期日期）。"""
    try:
        with open(STATE_FILE, 'r', encoding='utf-8') as f:
            return json.load(f)
    except Exception:
        return {}

def save_state(state: dict):
    try:
        with open(STATE_FILE, 'w', encoding='utf-8') as f:
            json.dump(state, f, ensure_ascii=False, indent=2)
    except Exception as e:
        logger.error(f"保存状态文件失败: {e}")

def should_skip_account(email: str, state: dict) -> Optional[str]:
    """
    判断该账号本次是否可以整体跳过（不登录、不触发验证码/邮箱PIN）。
    只有当该账号名下*所有*订单上次查到的"可续期日期"都还在未来时，才跳过；
    只要有一个订单已到期、或缺少历史记录，都必须照常执行一次去确认真实状态。
    返回值：None 表示需要执行；否则返回跳过原因（各订单的最早可续期日期说明）。
    """
    acc_state = state.get(email)
    if not acc_state or not acc_state.get('servers'):
        return None  # 没有历史记录，必须执行一次
    today = datetime.today().date()
    reasons = []
    for oid, info in acc_state['servers'].items():
        date_str = info.get('can_renew_date') if isinstance(info, dict) else None
        if not date_str:
            return None  # 缺少日期信息，保守起见照常执行
        try:
            d = datetime.strptime(date_str, "%Y-%m-%d").date()
        except ValueError:
            return None
        if d <= today:
            return None  # 至少有一个订单已到可续期日期，必须执行
        reasons.append(f"订单{oid}最早{date_str}可续期(剩{(d - today).days}天)")
    return "；".join(reasons) if reasons else None

def process_account(account_config: AccountConfig, global_config: GlobalConfig) -> Dict:
    result = {'email': account_config.email, 'success': False, 'servers': {}, 'renew_results': [], 'error': None}
    try:
        euserv = EUserv(account_config)
        login_success = False
        for _ in range(global_config.max_login_retries):
            if euserv.login():
                login_success = True
                break
            time.sleep(5)
        
        if not login_success:
            result['error'] = "登录失败"
            return result
        
        euserv.update_info()
        servers = euserv.get_servers()
        result['servers'] = servers
        
        if not servers:
            result['success'] = True
            return result
        
        any_renewed = False
        for order_id, (can_renew, can_renew_date) in servers.items():
            if can_renew:
                if euserv.renew_server(order_id):
                    result['renew_results'].append({'order_id': order_id, 'message': f"✅ 续期成功"})
                    any_renewed = True
                else:
                    result['renew_results'].append({'order_id': order_id, 'message': f"❌ 续期失败"})

        if any_renewed:
            # 续期后重新拉取一次服务器列表，获取续期后新的"可续期日期"，
            # 用于更新本地状态文件，让后续运行可以据此正确跳过。
            time.sleep(3)
            refreshed = euserv.get_servers()
            if refreshed:
                result['servers'] = refreshed

        result['success'] = True
    except Exception as e:
        result['error'] = str(e)
    return result

def main():
    if not ACCOUNTS: return

    # FORCE_RUN=1 时强制执行，忽略跳过逻辑（用于手动触发的"立即执行"）。
    force_run = os.getenv("FORCE_RUN", "").strip() == "1"
    state = load_state()

    accounts_to_run: List[AccountConfig] = []
    skipped: List[Tuple[str, str]] = []
    for account in ACCOUNTS:
        skip_reason = None if force_run else should_skip_account(account.email, state)
        if skip_reason:
            logger.info(f"⏭️ 跳过账号 {account.email}，尚未到可续期日期: {skip_reason}")
            skipped.append((account.email, skip_reason))
        else:
            accounts_to_run.append(account)

    if not accounts_to_run:
        # 所有账号都还没到续期窗口：不登录、不触发验证码/邮箱PIN、不发送TG通知，
        # 直接结束本次运行，避免每天空跑消耗资源。
        logger.info(f"本次运行 {len(skipped)} 个账号均未到续期窗口，跳过登录，直接结束。")
        return

    all_results = []
    with ThreadPoolExecutor(max_workers=GLOBAL_CONFIG.max_workers) as executor:
        future_to_account = {executor.submit(process_account, account, GLOBAL_CONFIG): account for account in accounts_to_run}
        for future in as_completed(future_to_account):
            try: all_results.append(future.result())
            except Exception as e: all_results.append({'email': future_to_account[future].email, 'success': False, 'error': str(e)})

    # 更新本地状态：记录每个订单最新的"可续期日期"，供下次运行判断是否可以跳过。
    for result in all_results:
        if result['success'] and result.get('servers'):
            state[result['email']] = {
                'servers': {oid: {'can_renew_date': date} for oid, (_, date) in result['servers'].items() if date},
                'last_check': datetime.now().strftime('%Y-%m-%d %H:%M:%S')
            }
    save_state(state)

    msg_parts = [f"<b>🔄 EUserv 续期报告</b>\n时间: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}"]
    for email, reason in skipped:
        msg_parts.append(f"\n<b>⏭️ {email}</b>\n  未到续期窗口，已跳过: {reason}")
    for result in all_results:
        msg_parts.append(f"\n<b>📧 {result['email']}</b>")
        if not result['success']:
            msg_parts.append(f"  ❌ 失败: {result.get('error')}")
            continue
        renew_results = result.get('renew_results', [])
        if renew_results:
            for r in renew_results: msg_parts.append(f"  {r['message']}")
        else:
            msg_parts.append("  ✓ 无需续期")
            for oid, (_, date) in result.get('servers', {}).items():
                if date: msg_parts.append(f"    订单 {oid}: {date}")

    send_telegram("\n".join(msg_parts), GLOBAL_CONFIG)

if __name__ == "__main__":
    main()
PYTHON_EOF

    chmod +x ${INSTALL_DIR}/euser_renew.py
    print_success "本地 Python 核心文件生成完成"
}

# ---------------------------------------------------------
# 安装配置交互逻辑
# ---------------------------------------------------------
configure_env() {
    print_info "配置环境变量..."

    if [[ -f "${CONFIG_FILE}" ]]; then
        print_warning "检测到已有配置文件：${CONFIG_FILE}"
        echo "1) 沿用旧配置（推荐：只更新脚本和依赖，不覆盖账号信息）"
        echo "2) 重新输入配置（先备份旧配置，再覆盖）"
        echo "3) 退出，不做修改"
        local cfg_choice
        read -p "请选择 [1/2/3]（默认 1）: " cfg_choice
        cfg_choice="${cfg_choice:-1}"
        case "$cfg_choice" in
            1)
                print_success "已沿用旧配置"
                ensure_config_defaults
                return
                ;;
            2)
                local bak_file="${CONFIG_FILE}.bak.$(date +%Y%m%d%H%M%S)"
                cp "${CONFIG_FILE}" "${bak_file}"
                chmod 600 "${bak_file}" 2>/dev/null || true
                print_success "旧配置已备份：${bak_file}"
                ;;
            3)
                print_info "已退出，未修改配置"
                exit 0
                ;;
            *)
                print_warning "无效选择，默认沿用旧配置"
                ensure_config_defaults
                return
                ;;
        esac
    fi

    read -p "请输入EUserv账号邮箱: " email
    read -sp "请输入EUserv账号密码: " password
    echo ""
    read -sp "请输入邮箱应用专用密码(EMAIL_PASS): " email_pass
    echo ""
    echo ""
    print_info "=== 可选项(Telegram推送配置) ==="
    print_info "提示: 如果不需要推送，请直接按回车跳过。"
    read -p "Telegram Bot Token: " tg_bot_token
    read -p "Telegram Chat ID: " tg_chat_id
    echo ""

    cat > ${CONFIG_FILE} <<EOF
EUSERV_EMAIL=${email}
EUSERV_PASSWORD=${password}
EMAIL_PASS=${email_pass}
TG_BOT_TOKEN=${tg_bot_token}
TG_CHAT_ID=${tg_chat_id}
CAPTCHA_MAX_RETRIES=6
CAPTCHA_RETRY_DELAY=4
TZ=Asia/Shanghai
EOF
    chmod 600 ${CONFIG_FILE}
}

ensure_config_defaults() {
    [[ -f "${CONFIG_FILE}" ]] || return 0
    grep -q '^CAPTCHA_MAX_RETRIES=' "${CONFIG_FILE}" || echo 'CAPTCHA_MAX_RETRIES=6' >> "${CONFIG_FILE}"
    grep -q '^CAPTCHA_RETRY_DELAY=' "${CONFIG_FILE}" || echo 'CAPTCHA_RETRY_DELAY=4' >> "${CONFIG_FILE}"
    grep -q '^TZ=' "${CONFIG_FILE}" || echo 'TZ=Asia/Shanghai' >> "${CONFIG_FILE}"
    chmod 600 "${CONFIG_FILE}"
}

install_python() {
    print_info "安装系统依赖 (tesseract-ocr)..."
    apt-get update -qq
    apt-get install -y python3 python3-full python3-venv tesseract-ocr -qq

    PYTHON_BIN=$(command -v python3)
    [[ -z "$PYTHON_BIN" ]] && { print_error "Python 安装失败"; exit 1; }
    print_success "Python: $PYTHON_BIN ($("$PYTHON_BIN" --version 2>&1))"

    local VENV_DIR="${INSTALL_DIR}/venv"
    print_info "创建虚拟环境: $VENV_DIR"
    "$PYTHON_BIN" -m venv --copies "$VENV_DIR"

    if [[ ! -f "${VENV_DIR}/bin/pip" ]]; then
        print_warning "venv 缺少 pip，通过 get-pip.py 补装..."
        curl -sS https://bootstrap.pypa.io/get-pip.py | "${VENV_DIR}/bin/python3"
    fi

    print_info "安装 Python 依赖..."
    "${VENV_DIR}/bin/pip" install --upgrade pip -q
    if ! "${VENV_DIR}/bin/pip" install -r "${INSTALL_DIR}/requirements.txt"; then
        print_error "依赖安装失败"; exit 1
    fi

    print_success "虚拟环境就绪: $VENV_DIR"
}

setup_timer() {
    local hour=$1
    cat > /etc/systemd/system/${SERVICE_NAME}.service <<EOF
[Unit]
Description=EUserv Auto Renew Service
After=network.target

[Service]
Type=oneshot
WorkingDirectory=${INSTALL_DIR}
EnvironmentFile=${CONFIG_FILE}
ExecStart=${INSTALL_DIR}/venv/bin/python3 ${INSTALL_DIR}/euser_renew.py
EOF

    cat > /etc/systemd/system/${SERVICE_NAME}.timer <<EOF
[Timer]
OnCalendar=*-*-* ${hour}:00:00
Persistent=true
[Install]
WantedBy=timers.target
EOF

    systemctl daemon-reload
    systemctl enable ${SERVICE_NAME}.timer
    systemctl start ${SERVICE_NAME}.timer
}

uninstall_euserv_renew() {
    echo ""
    print_warning "即将完整卸载 EUserv 自动续期脚本"
    echo "将删除："
    echo "  - systemd 服务和定时器：${SERVICE_NAME}.service / ${SERVICE_NAME}.timer"
    echo "  - 安装目录：${INSTALL_DIR}"
    echo "  - 快捷命令：${COMMAND_LINK}"
    echo ""
    read -p "确认卸载？请输入 YES 继续: " confirm
    [[ "$confirm" == "YES" ]] || { print_info "已取消卸载"; return; }

    systemctl stop ${SERVICE_NAME}.timer 2>/dev/null || true
    systemctl disable ${SERVICE_NAME}.timer 2>/dev/null || true
    systemctl stop ${SERVICE_NAME}.service 2>/dev/null || true
    rm -f /etc/systemd/system/${SERVICE_NAME}.service
    rm -f /etc/systemd/system/${SERVICE_NAME}.timer
    systemctl daemon-reload 2>/dev/null || true
    systemctl reset-failed ${SERVICE_NAME}.service ${SERVICE_NAME}.timer 2>/dev/null || true
    rm -rf "${INSTALL_DIR}"
    rm -f "${COMMAND_LINK}"
    print_success "EUserv 自动续期脚本已完整卸载"
}

# 创建快捷命令
create_command() {
    cat > ${COMMAND_LINK} <<EOF
#!/bin/bash
INSTALL_DIR="${INSTALL_DIR}"
SERVICE_NAME="${SERVICE_NAME}"
COMMAND_LINK="${COMMAND_LINK}"

echo "EUserv 管理面板 (离线完全体版)"
echo "1. 立即执行（遵循跳过逻辑，未到续期窗口则秒退，同定时任务）"
echo "2. 强制立即执行（忽略跳过逻辑，一定会登录检查）"
echo "3. 查看日志"
echo "4. 查看续期状态（各订单下次可续期日期）"
echo "5. 查看定时器状态"
echo "6. 完整卸载"
echo "0. 退出"
read -p "选择: " c
case \$c in
    1) systemctl start \${SERVICE_NAME}.service && journalctl -u \${SERVICE_NAME}.service -f ;;
    2)
        set -a
        source "\${INSTALL_DIR}/config.env"
        set +a
        FORCE_RUN=1 "\${INSTALL_DIR}/venv/bin/python3" "\${INSTALL_DIR}/euser_renew.py"
        ;;
    3) journalctl -u \${SERVICE_NAME}.service -n 80 --no-pager ;;
    4)
        if [[ -f "\${INSTALL_DIR}/renew_state.json" ]]; then
            "\${INSTALL_DIR}/venv/bin/python3" -m json.tool "\${INSTALL_DIR}/renew_state.json"
        else
            echo "暂无状态记录（尚未成功执行过一次）"
        fi
        ;;
    5) systemctl status \${SERVICE_NAME}.timer --no-pager ;;
    6)
        echo ""
        echo "即将完整卸载 EUserv 自动续期脚本"
        echo "将删除："
        echo "  - systemd 服务和定时器：\${SERVICE_NAME}.service / \${SERVICE_NAME}.timer"
        echo "  - 安装目录：\${INSTALL_DIR}"
        echo "  - 快捷命令：\${COMMAND_LINK}"
        echo ""
        read -p "确认卸载？请输入 YES 继续: " confirm
        if [[ "\$confirm" == "YES" ]]; then
            systemctl stop \${SERVICE_NAME}.timer 2>/dev/null || true
            systemctl disable \${SERVICE_NAME}.timer 2>/dev/null || true
            systemctl stop \${SERVICE_NAME}.service 2>/dev/null || true
            rm -f /etc/systemd/system/\${SERVICE_NAME}.service
            rm -f /etc/systemd/system/\${SERVICE_NAME}.timer
            systemctl daemon-reload 2>/dev/null || true
            systemctl reset-failed \${SERVICE_NAME}.service \${SERVICE_NAME}.timer 2>/dev/null || true
            rm -rf "\${INSTALL_DIR}"
            rm -f "\${COMMAND_LINK}"
            echo "卸载完成"
        else
            echo "已取消卸载"
        fi
        ;;
esac
EOF
    chmod +x ${COMMAND_LINK}
}

# 主程序
main() {
    check_root
    create_directories
    generate_local_files
    configure_env
    install_python
    setup_timer 3
    create_command
    print_success "安装完成！使用 'dj' 命令管理。"
}

main
