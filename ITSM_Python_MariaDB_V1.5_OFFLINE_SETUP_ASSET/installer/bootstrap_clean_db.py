import os
import sys

try:
    sys.stdout.reconfigure(encoding='utf-8', errors='backslashreplace')
    sys.stderr.reconfigure(encoding='utf-8', errors='backslashreplace')
except Exception:
    pass

sys.path.insert(0, os.getcwd())

from app import app
from models import db, Category, AppSetting
from seed_demo import seed_demo_data, DEMO_PASSWORD

DEFAULT_CATEGORIES = [
    ('Sự cố máy tính / Laptop', 8),
    ('Không truy cập Internet / Wi-Fi', 4),
    ('Mạng LAN chậm / mất kết nối', 4),
    ('Không in được / lỗi máy in', 8),
    ('Email / Microsoft 365 / Teams', 8),
    ('Quên mật khẩu / khóa tài khoản', 4),
    ('Cài đặt phần mềm', 16),
    ('Virus / nghi ngờ mã độc', 2),
    ('Không truy cập phần mềm nội bộ', 4),
    ('Yêu cầu cấp quyền truy cập', 16),
    ('Yêu cầu cấp mới thiết bị CNTT', 24),
    ('Camera / CCTV', 8),
    ('Điện thoại / thiết bị di động', 8),
    ('VPN / làm việc từ xa', 4),
    ('Khác', 8),
]

mode = os.environ.get('ITSM_DATA_MODE', 'clean').strip().lower()
if mode not in ('clean', 'demo'):
    mode = 'clean'

with app.app_context():
    db.create_all()
    for name, sla in DEFAULT_CATEGORIES:
        if not Category.query.filter_by(name=name).first():
            db.session.add(Category(name=name, sla_hours=sla, is_active=True))
    defaults = {
        'company_name': 'IT Service Management',
        'support_name': 'Bộ phận CNTT',
        'default_sla_hours': '8',
        'auto_close_minutes': '30',
    }
    for key, value in defaults.items():
        if not AppSetting.query.filter_by(key=key).first():
            db.session.add(AppSetting(key=key, value=value))
    db.session.commit()

    if mode == 'demo':
        result = seed_demo_data()
        print(f"OK: Demo data initialized - {result['users']} users, {result['tickets']} tickets, {result.get('assets', 0)} assets.")
        print(f'INFO: Demo password for tech01/tech02/user01..user05: {DEMO_PASSWORD}')
    else:
        print('OK: Clean mode - no sample users/tickets created.')

print(f'OK: ITSM schema/default catalog initialized. Data mode: {mode}.')
