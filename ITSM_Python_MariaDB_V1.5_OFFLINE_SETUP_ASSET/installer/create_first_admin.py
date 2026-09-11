import os
import sys
import traceback

try:
    sys.stdout.reconfigure(encoding='utf-8', errors='backslashreplace')
    sys.stderr.reconfigure(encoding='utf-8', errors='backslashreplace')
except Exception:
    pass

sys.path.insert(0, os.getcwd())
from app import app
from models import db, User


def main():
    username = os.environ.get('ITSM_ADMIN_USERNAME', '').strip()
    password = os.environ.get('ITSM_ADMIN_PASSWORD', '')
    full_name = os.environ.get('ITSM_ADMIN_NAME', '').strip()
    if not username or not full_name or len(password) < 8:
        print('ERROR: Invalid first-admin parameters.', file=sys.stderr)
        return 2
    try:
        with app.app_context():
            if User.query.filter_by(username=username).first():
                print('ERROR: Admin username already exists.', file=sys.stderr)
                return 3
            u = User(username=username, full_name=full_name, role='admin', is_active=True)
            u.set_password(password)
            db.session.add(u)
            db.session.commit()
            print(f'OK: First ITSM admin created: {username}')
            return 0
    except Exception:
        try: db.session.rollback()
        except Exception: pass
        print('ERROR: Could not create first ITSM admin.', file=sys.stderr)
        traceback.print_exc(file=sys.stderr)
        return 11

if __name__ == '__main__':
    raise SystemExit(main())
