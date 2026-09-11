import sys
MODULES = [
    'flask', 'flask_sqlalchemy', 'pymysql', 'dotenv', 'waitress',
    'sqlalchemy', 'greenlet', 'openpyxl', 'et_xmlfile'
]
print('Python:', sys.executable)
print('Version:', sys.version.split()[0])
if sys.version_info[:2] != (3, 13):
    raise SystemExit('ERROR: ITSM offline runtime requires Python 3.13')
for name in MODULES:
    __import__(name)
    print('[OK] import', name)
print('OK: ITSM Python runtime offline ready')
