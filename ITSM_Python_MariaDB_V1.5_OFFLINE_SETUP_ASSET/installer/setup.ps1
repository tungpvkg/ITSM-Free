#requires -version 5.1
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$ProductName = 'ITSM'
$ProductVersion = '1.5'
$InstallDir = 'C:\ITSMService'
$DataDir = Join-Path $env:ProgramData 'ITSMService'
$DbName = 'itsm_db'
$DbUser = 'itsm_app'
$DbPort = 3306
$AppPort = 8088
$MariaVersion = '12.3.3'
$PackageRoot = Split-Path -Parent $PSScriptRoot
$MariaMsi = Join-Path $PackageRoot 'mariadb-12.3.3-winx64.msi'
$PythonLocal1 = Join-Path $PackageRoot 'python-3-13-5-amd64.exe'
$PythonLocal2 = Join-Path $PackageRoot 'python-3.13.5-amd64.exe'
$PayloadZip = Join-Path $PSScriptRoot 'app_payload.zip'
$DepsZip = Join-Path $PSScriptRoot 'python_site_packages_cp313_win_amd64.zip'
$BootstrapPy = Join-Path $PSScriptRoot 'bootstrap_clean_db.py'
$VerifyRuntimePy = Join-Path $PSScriptRoot 'verify_runtime.py'
$CreateFirstAdminPy = Join-Path $PSScriptRoot 'create_first_admin.py'
$BuildId = 'V1.5-R2-ASSET-20260907'
$InstallerPasswordSha256 = 'c775e7b757ede630cd0aa1113bd102661ab38829ca52a6422ab782862f268646'
$PayloadSha256 = '0c7d962d31b8b348d5654559d26bd8923b4ca15e3cc7a07e82ffde64bb9500b1'
$DepsSha256 = 'b38bc9f15a791e99bef9fc8a483159b9b4e94ebf56b6537cecd06651d173481d'
$BootstrapSha256 = '11e312d09a90789b92c91188eda7ff1083fdab328a3b270f26ee016255a87e3a'
$VerifyRuntimeSha256 = 'dfeb069ea56e2493332dc255c4b38e2a566d6042ba12d3350c1b1e091e840b69'
$CreateFirstAdminSha256 = '6294793f51defdedd2ea36fa44ecea6dbe2e44072aedab2031dfa94983bc9adb'
$InstallStateFile = Join-Path $DataDir 'INSTALL_STATE.json'
$InstallOkFlag = Join-Path $DataDir 'INSTALL_OK.flag'
$RecoveryFile = Join-Path $DataDir 'MARIADB_RECOVERY_ADMIN_ONLY.txt'
$InstallInfoFile = Join-Path $DataDir 'INSTALL_INFO_ADMIN_ONLY.txt'

$script:InstalledMariaByThisSetup = $false
$script:MariaRootPassword = $null
$script:DbAppPassword = $null
$script:DbCreatedThisRun = $false
$script:DbUserCreatedThisRun = $false
$script:AppCreatedThisRun = $false
$script:MariaCliForRollback = $null
$script:DataMode = 'clean'

function Write-Step([string]$Message) { Write-Host "`n==> $Message" -ForegroundColor Cyan }
function Write-Ok([string]$Message) { Write-Host "[OK] $Message" -ForegroundColor Green }
function Write-Warn([string]$Message) { Write-Host "[CANH BAO] $Message" -ForegroundColor Yellow }
function Pause-End { Write-Host ''; Read-Host 'Nhan Enter de dong cua so cai dat' | Out-Null }

# Windows PowerShell 5.1 co the bien bat ky du lieu STDERR cua chuong trinh native
# thanh ErrorRecord. Khi $ErrorActionPreference='Stop', mot CANH BAO cua Python co the
# lam Setup dung ngay ca khi exit code = 0. Ham nay chi quyet dinh loi theo exit code.
function Invoke-NativeLogged([string]$FilePath, [string[]]$Arguments) {
    $oldEap = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        & $FilePath @Arguments 2>&1 | ForEach-Object { Write-Host $_ }
        $rc = $LASTEXITCODE
        return [int]$rc
    }
    finally {
        $ErrorActionPreference = $oldEap
    }
}

function Convert-SecureToPlain([Security.SecureString]$Secure) {
    $ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Secure)
    try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr) }
}

function Get-Sha256([string]$Text) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes($Text)
        return ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-', '').ToLowerInvariant()
    }
    finally { $sha.Dispose() }
}

function Assert-FileSha256([string]$Path, [string]$Expected, [string]$Label) {
    if (-not (Test-Path $Path)) { throw "Thieu file: $Path" }
    $actual = (Get-FileHash -Path $Path -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actual -ne $Expected.ToLowerInvariant()) {
        throw "File $Label bi thay doi/hong. SHA256 khong khop. Hay giai nen lai bo Setup ITSM V1.5 goc."
    }
    Write-Ok "Checksum OK: $Label"
}

function New-RandomText([int]$Length = 32) {
    $chars = 'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789'
    $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
    try {
        $bytes = New-Object byte[] $Length
        $rng.GetBytes($bytes)
        $sb = New-Object Text.StringBuilder
        foreach ($b in $bytes) { [void]$sb.Append($chars[$b % $chars.Length]) }
        return $sb.ToString()
    }
    finally { $rng.Dispose() }
}

function New-SecretKey {
    $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
    try {
        $bytes = New-Object byte[] 48
        $rng.GetBytes($bytes)
        return [Convert]::ToBase64String($bytes)
    }
    finally { $rng.Dispose() }
}

function Test-Admin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Confirm-InstallerPassword {
    Write-Host '============================================================' -ForegroundColor DarkCyan
    Write-Host ' ITSM V1.5 - OFFLINE ONE CLICK SETUP - ASSET' -ForegroundColor White
    Write-Host " Build: $BuildId" -ForegroundColor DarkGray
    Write-Host '============================================================' -ForegroundColor DarkCyan
    Write-Host 'Khong can Internet. MariaDB va Python phai dat cung thu muc Setup.'
    for ($i = 1; $i -le 3; $i++) {
        $secure = Read-Host 'Mat khau cai dat' -AsSecureString
        $plain = Convert-SecureToPlain $secure
        try {
            if ((Get-Sha256 $plain) -eq $InstallerPasswordSha256) {
                Write-Ok 'Mat khau cai dat hop le.'
                return
            }
        }
        finally { $plain = $null }
        Write-Warn "Sai mat khau. Lan thu $i/3."
    }
    throw 'Sai mat khau cai dat qua 3 lan.'
}

function Protect-SecretFile([string]$Path) {
    try {
        $acl = New-Object Security.AccessControl.FileSecurity
        $acl.SetAccessRuleProtection($true, $false)
        $admins = New-Object Security.Principal.SecurityIdentifier('S-1-5-32-544')
        $system = New-Object Security.Principal.SecurityIdentifier('S-1-5-18')
        $rule1 = New-Object Security.AccessControl.FileSystemAccessRule($admins, 'FullControl', 'Allow')
        $rule2 = New-Object Security.AccessControl.FileSystemAccessRule($system, 'FullControl', 'Allow')
        $acl.AddAccessRule($rule1); $acl.AddAccessRule($rule2)
        Set-Acl -Path $Path -AclObject $acl
    }
    catch { Write-Warn "Khong dat duoc ACL rieng cho $Path" }
}

function Write-InstallState([string]$Status, [string]$Message = '') {
    New-Item -ItemType Directory -Path $DataDir -Force | Out-Null
    $obj = [ordered]@{
        product = $ProductName
        version = $ProductVersion
        status = $Status
        time = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
        database_created_this_run = $script:DbCreatedThisRun
        database_user_touched_this_run = $script:DbUserCreatedThisRun
        app_created_this_run = $script:AppCreatedThisRun
        message = $Message
    }
    $obj | ConvertTo-Json | Set-Content -Path $InstallStateFile -Encoding UTF8
}

function Find-MariaCli {
    $cmd = Get-Command mariadb.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $cmd = Get-Command mysql.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $hits = @()
    if ($env:ProgramFiles) {
        $hits += Get-ChildItem -Path (Join-Path $env:ProgramFiles 'MariaDB*\bin\mariadb.exe') -ErrorAction SilentlyContinue
        $hits += Get-ChildItem -Path (Join-Path $env:ProgramFiles 'MariaDB*\bin\mysql.exe') -ErrorAction SilentlyContinue
    }
    $hit = $hits | Sort-Object FullName -Descending | Select-Object -First 1
    if ($hit) { return $hit.FullName }
    return $null
}

function Get-MariaService {
    return Get-Service -ErrorAction SilentlyContinue | Where-Object { $_.Name -like 'MariaDB*' -or $_.DisplayName -like 'MariaDB*' } | Select-Object -First 1
}

function Test-SignedInstaller([string]$Path, [string]$PublisherRegex) {
    if (-not (Test-Path $Path)) { return $false }
    $sig = Get-AuthenticodeSignature -FilePath $Path
    if ($sig.Status -ne 'Valid') { return $false }
    if (-not $sig.SignerCertificate) { return $false }
    return ($sig.SignerCertificate.Subject -match $PublisherRegex)
}

function Get-LocalPythonInstaller {
    if (Test-Path $PythonLocal1) { return $PythonLocal1 }
    if (Test-Path $PythonLocal2) { return $PythonLocal2 }
    return $null
}

function Save-MariaRecoveryInfo {
    if (-not $script:MariaRootPassword) { return }
    New-Item -ItemType Directory -Path $DataDir -Force | Out-Null
    $content = @"
ITSM - MARIADB RECOVERY
Created: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
MariaDB root password: $($script:MariaRootPassword)
Service: MariaDB
Port: $DbPort

CHI DAN: File nay duoc tao NGAY SAU KHI CAI MariaDB de co the phuc hoi neu Setup loi o buoc sau.
"@
    Set-Content -Path $RecoveryFile -Value $content -Encoding UTF8
    Protect-SecretFile $RecoveryFile
}

function Read-RecoveryRootPassword {
    if (-not (Test-Path $RecoveryFile)) { return $null }
    try {
        $line = Get-Content $RecoveryFile | Where-Object { $_ -like 'MariaDB root password:*' } | Select-Object -First 1
        if ($line) { return ($line -replace '^MariaDB root password:\s*', '').Trim() }
    }
    catch {}
    return $null
}

function Install-MariaDbLocal {
    Write-Step "Cai MariaDB $MariaVersion tu file local..."
    if (-not (Test-Path $MariaMsi)) {
        throw "Thieu file $([IO.Path]::GetFileName($MariaMsi)). Hay copy file nay nam CUNG THU MUC voi SETUP_ITSM.cmd."
    }
    if ((Get-Item $MariaMsi).Length -lt 1000000) { throw 'File MariaDB MSI qua nho/khong hop le.' }
    if (-not (Test-SignedInstaller $MariaMsi 'MariaDB')) { throw 'Chu ky so cua bo cai MariaDB khong hop le.' }
    Write-Ok 'Da xac minh chu ky so MariaDB.'

    $script:MariaRootPassword = New-RandomText 28
    $args = @('/i', ('"{0}"' -f $MariaMsi), '/qn', '/norestart', 'SERVICENAME=MariaDB', "PORT=$DbPort", "PASSWORD=$($script:MariaRootPassword)", 'UTF8=1')
    $proc = Start-Process -FilePath 'msiexec.exe' -ArgumentList $args -Wait -PassThru
    if ($proc.ExitCode -notin @(0,3010)) { throw "MariaDB MSI loi, ma: $($proc.ExitCode)" }
    Start-Sleep -Seconds 3
    $svc = Get-MariaService
    if (-not $svc) { throw 'Khong tim thay Windows Service MariaDB sau khi cai.' }
    if ($svc.Status -ne 'Running') { Start-Service -Name $svc.Name; Start-Sleep -Seconds 2 }
    $script:InstalledMariaByThisSetup = $true
    Save-MariaRecoveryInfo
    Write-Ok "MariaDB da san sang (Service: $($svc.Name))."
}

function Find-MariaUninstallEntry {
    $roots = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    $all = foreach ($r in $roots) { Get-ItemProperty $r -ErrorAction SilentlyContinue }
    return $all | Where-Object { $_.DisplayName -like 'MariaDB*' } | Sort-Object DisplayVersion -Descending | Select-Object -First 1
}

function Get-MariaInstallRoot([string]$Cli) {
    if (-not $Cli) { return $null }
    try { return (Split-Path -Parent (Split-Path -Parent $Cli)) } catch { return $null }
}

function Remove-LegacyPartialMariaDb {
    Write-Host ''
    Write-Warn 'Phat hien dau vet LAN CAI DAT DO cua bo Setup cu.'
    Write-Host 'Bo Setup cu co the da tao MariaDB root password ngau nhien nhung chua kip luu lai.' -ForegroundColor Yellow
    Write-Host 'Neu day dung la may vua cai thu va KHONG co database MariaDB quan trong khac, go: GOMARIADB' -ForegroundColor Yellow
    $confirm = Read-Host 'Xac nhan go MariaDB/data cua lan cai do'
    if ($confirm -cne 'GOMARIADB') { return $false }

    $cli = Find-MariaCli
    $installRoot = Get-MariaInstallRoot $cli
    $svc = Get-MariaService
    if ($svc) {
        Stop-Service -Name $svc.Name -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 1
    }

    $entry = Find-MariaUninstallEntry
    if ($entry -and $entry.PSChildName -match '^\{[0-9A-Fa-f-]+\}$') {
        Write-Step "Go $($entry.DisplayName)..."
        $p = Start-Process -FilePath 'msiexec.exe' -ArgumentList @('/x', $entry.PSChildName, '/qn', '/norestart') -Wait -PassThru
        if ($p.ExitCode -notin @(0,1605,3010)) { Write-Warn "MSI uninstall tra ma $($p.ExitCode). Tiep tuc don service/folder." }
    }
    elseif ($entry -and $entry.UninstallString) {
        Write-Warn 'Khong nhan duoc ProductCode MSI ro rang; se don service/folder sau khi xac nhan.'
    }

    $svc2 = Get-MariaService
    if ($svc2) {
        & sc.exe stop $svc2.Name | Out-Null
        & sc.exe delete $svc2.Name | Out-Null
        Start-Sleep -Seconds 1
    }

    if ($installRoot -and $installRoot -like "$env:ProgramFiles\MariaDB*") {
        Remove-Item $installRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
    Remove-Item $InstallDir -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item $InstallStateFile -Force -ErrorAction SilentlyContinue
    Remove-Item $InstallOkFlag -Force -ErrorAction SilentlyContinue
    Remove-Item $RecoveryFile -Force -ErrorAction SilentlyContinue
    Remove-Item $InstallInfoFile -Force -ErrorAction SilentlyContinue
    Write-Ok 'Da don lan cai MariaDB/app dang do. Setup se cai lai sach tu file MSI local.'
    return $true
}

function Test-MariaRoot([string]$Cli, [string]$Password) {
    $old = $env:MYSQL_PWD
    try {
        $env:MYSQL_PWD = $Password
        $out = & $Cli -u root -N -e 'SELECT 1;' 2>$null
        return ($LASTEXITCODE -eq 0 -and ($out -join '') -match '1')
    }
    finally { $env:MYSQL_PWD = $old }
}

function Ensure-MariaRootAccess([string]$Cli) {
    if ($script:InstalledMariaByThisSetup -and (Test-MariaRoot $Cli $script:MariaRootPassword)) { return }
    $saved = Read-RecoveryRootPassword
    if ($saved -and (Test-MariaRoot $Cli $saved)) {
        $script:MariaRootPassword = $saved
        Write-Ok 'Da lay lai MariaDB root password tu file phuc hoi cua Setup.'
        return
    }
    Write-Host ''
    Write-Host 'May nay da co MariaDB. Can mat khau root MariaDB hien tai.' -ForegroundColor Yellow
    for ($i=1; $i -le 3; $i++) {
        $s = Read-Host 'Mat khau root MariaDB' -AsSecureString
        $p = Convert-SecureToPlain $s
        if (Test-MariaRoot $Cli $p) { $script:MariaRootPassword = $p; return }
        $p = $null
        Write-Warn "Khong dang nhap duoc root MariaDB. Lan thu $i/3."
    }
    throw 'Khong xac thuc duoc root MariaDB.'
}

function Invoke-MariaSql([string]$Cli, [string]$Sql) {
    $old = $env:MYSQL_PWD
    try {
        $env:MYSQL_PWD = $script:MariaRootPassword
        $rc = Invoke-NativeLogged -FilePath $Cli -Arguments @('-u','root','-e',$Sql)
        if ($rc -ne 0) { throw "Lenh SQL MariaDB that bai (exit $rc)." }
    }
    finally { $env:MYSQL_PWD = $old }
}

function Test-DbExists([string]$Cli) {
    $old = $env:MYSQL_PWD
    try {
        $env:MYSQL_PWD = $script:MariaRootPassword
        $out = & $Cli -u root -N -e "SELECT SCHEMA_NAME FROM INFORMATION_SCHEMA.SCHEMATA WHERE SCHEMA_NAME='$DbName';" 2>$null
        return (($out -join '').Trim() -eq $DbName)
    }
    finally { $env:MYSQL_PWD = $old }
}

function Remove-AppDatabaseAndUser([string]$Cli) {
    if (-not $Cli -or -not $script:MariaRootPassword) { return }
    $sql = @"
DROP DATABASE IF EXISTS ``$DbName``;
DROP USER IF EXISTS '$DbUser'@'localhost';
DROP USER IF EXISTS '$DbUser'@'127.0.0.1';
FLUSH PRIVILEGES;
"@
    try {
        Invoke-MariaSql $Cli $sql
        Write-Ok 'Da go database/user ITSM dang do.'
    }
    catch { Write-Warn "Khong go het database/user dang do: $($_.Exception.Message)" }
}

function Resolve-PartialFromFixedSetup([string]$Cli) {
    if (-not (Test-Path $InstallStateFile)) { return }
    try { $state = Get-Content $InstallStateFile -Raw | ConvertFrom-Json } catch { return }
    if ($state.status -eq 'complete') { return }
    if ($state.status -eq 'failed_rolled_back') {
        Write-Warn 'Phat hien lan cai truoc da loi va da rollback. Tu dong don state con lai.'
        Remove-AppDatabaseAndUser $Cli
        Remove-Item $InstallDir -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item $InstallStateFile -Force -ErrorAction SilentlyContinue
        Remove-Item $InstallOkFlag -Force -ErrorAction SilentlyContinue
        Write-Ok 'Da don state cua lan cai loi truoc.'
        return
    }
    Write-Warn "Phat hien state cua lan cai truoc: $($state.status)."
    $confirm = Read-Host 'Go database/user + thu muc app dang do de cai lai sach? Go DONDEP'
    if ($confirm -cne 'DONDEP') { throw 'Da huy de tranh xoa du lieu dang do.' }
    Remove-AppDatabaseAndUser $Cli
    Remove-Item $InstallDir -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item $InstallStateFile -Force -ErrorAction SilentlyContinue
    Remove-Item $InstallOkFlag -Force -ErrorAction SilentlyContinue
    Write-Ok 'Da don sach lan cai dat do.'
}

function Select-InitialDataMode {
    Write-Step 'Chon du lieu ban dau cho he thong...'
    Write-Host '  [1] DU LIEU SACH - chi tao danh muc/cau hinh, khong tao User/Ticket mau.' -ForegroundColor White
    Write-Host '  [2] DU LIEU DEMO - tao day du User/Technical, Ticket, phan hoi va Audit Log mau.' -ForegroundColor White
    Write-Host 'Admin dau tien van do ban tu tao o buoc sau.' -ForegroundColor DarkGray
    while ($true) {
        $choice = Read-Host 'Lua chon [1]'
        if ([string]::IsNullOrWhiteSpace($choice) -or $choice -eq '1') {
            $script:DataMode = 'clean'
            Write-Ok 'Da chon DU LIEU SACH.'
            return
        }
        if ($choice -eq '2') {
            $script:DataMode = 'demo'
            Write-Ok 'Da chon DU LIEU DEMO.'
            Write-Host 'Tai khoan demo se duoc tao: tech01, tech02, user01..user05 / mat khau Demo@123' -ForegroundColor Yellow
            return
        }
        Write-Warn 'Lua chon khong hop le. Nhap 1 hoac 2.'
    }
}

function Prepare-CleanDatabase([string]$Cli) {
    Write-Step 'Tao database sach va tai khoan DB rieng cho ung dung...'
    if (Test-DbExists $Cli) {
        if (Test-Path $InstallOkFlag) {
            Write-Warn "Database '$DbName' thuoc mot lan cai HOAN TAT truoc do."
            $confirm = Read-Host 'Muon XOA SACH du lieu cu de cai moi? Go XOA'
            if ($confirm -cne 'XOA') { throw 'Da huy de bao ve database hien co.' }
        }
        else {
            Write-Warn "Database '$DbName' ton tai nhung khong co co hoan tat; co the la lan cai dang do."
            $confirm = Read-Host 'Go database/user dang do? Go DONDEP'
            if ($confirm -cne 'DONDEP') { throw 'Da huy de bao ve database hien co.' }
        }
        Remove-AppDatabaseAndUser $Cli
    }

    $script:DbAppPassword = New-RandomText 32
    $dbPassSql = $script:DbAppPassword.Replace("'", "''")
    $sql = @"
CREATE DATABASE ``$DbName`` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '$DbUser'@'localhost' IDENTIFIED BY '$dbPassSql';
CREATE USER IF NOT EXISTS '$DbUser'@'127.0.0.1' IDENTIFIED BY '$dbPassSql';
ALTER USER '$DbUser'@'localhost' IDENTIFIED BY '$dbPassSql';
ALTER USER '$DbUser'@'127.0.0.1' IDENTIFIED BY '$dbPassSql';
GRANT ALL PRIVILEGES ON ``$DbName``.* TO '$DbUser'@'localhost';
GRANT ALL PRIVILEGES ON ``$DbName``.* TO '$DbUser'@'127.0.0.1';
FLUSH PRIVILEGES;
"@
    Invoke-MariaSql $Cli $sql
    $script:DbCreatedThisRun = $true
    $script:DbUserCreatedThisRun = $true
    Write-InstallState 'in_progress' 'Database created'
    Write-Ok "Database '$DbName' da tao sach; user DB: $DbUser."
}

function Find-Python313 {
    $paths = @(
        "$env:ProgramFiles\Python313\python.exe",
        "$env:LocalAppData\Programs\Python\Python313\python.exe"
    )
    foreach ($p in $paths) {
        if (Test-Path $p) {
            try {
                $v = (& $p --version 2>&1 | Select-Object -First 1)
                if (($v -join '') -match '^Python 3\.13\.') { return $p }
            } catch {}
        }
    }

    $cmd = Get-Command python.exe -ErrorAction SilentlyContinue
    if ($cmd) {
        try {
            $v = (& $cmd.Source --version 2>&1 | Select-Object -First 1)
            if (($v -join '') -match '^Python 3\.13\.') { return $cmd.Source }
        } catch {}
    }

    # Python Launcher can list interpreter paths without using python -c.
    $py = Get-Command py.exe -ErrorAction SilentlyContinue
    if ($py) {
        try {
            $lines = & $py.Source -0p 2>$null
            foreach ($line in $lines) {
                if ($line -match '3\.13' -and $line -match '([A-Za-z]:\\.*python\.exe)\s*$') {
                    $candidate = $Matches[1].Trim()
                    if (Test-Path $candidate) { return $candidate }
                }
            }
        } catch {}
    }
    return $null
}

function Install-Python313Local {
    Write-Step 'Cai Python 3.13.5 tu file local...'
    $exe = Get-LocalPythonInstaller
    if (-not $exe) {
        throw 'Thieu python-3-13-5-amd64.exe (hoac python-3.13.5-amd64.exe). Hay dat file cung thu muc voi Setup.'
    }
    if ((Get-Item $exe).Length -lt 1000000) { throw 'File Python installer qua nho/khong hop le.' }
    if (-not (Test-SignedInstaller $exe 'Python Software Foundation')) { throw 'Chu ky so cua bo cai Python khong hop le.' }
    Write-Ok 'Da xac minh chu ky so Python.'
    $proc = Start-Process -FilePath $exe -ArgumentList '/quiet InstallAllUsers=1 PrependPath=1 Include_test=0 Include_launcher=1' -Wait -PassThru
    if ($proc.ExitCode -ne 0) { throw "Bo cai Python loi, ma: $($proc.ExitCode)" }
    Start-Sleep -Seconds 2
    $found = Find-Python313
    if (-not $found) { throw 'Da cai Python nhung khong tim thay python.exe.' }
    Write-Ok "Python 3.13: $found"
    return $found
}

function Stop-OldITSM {
    try {
        $procs = Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
            ($_.Name -eq 'python.exe' -or $_.Name -eq 'pythonw.exe') -and
            $_.CommandLine -and $_.CommandLine -like "*$InstallDir*server.py*"
        }
        foreach ($p in $procs) { Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue }
    }
    catch {}
}

function Install-AppFiles {
    Write-Step 'Chep ITSM V1.5 vao may...'
    Stop-OldITSM
    if (Test-Path $InstallDir) {
        if (Test-Path $InstallOkFlag) {
            $confirm = Read-Host 'Thu muc app cu la ban da cai hoan tat. Go THAYTHE de cai sach lai phan app'
        }
        else {
            $confirm = Read-Host "Thu muc $InstallDir da ton tai. Go THAYTHE de thay the bang ban cai sach"
        }
        if ($confirm -cne 'THAYTHE') { throw 'Da huy de bao ve thu muc app hien co.' }
        Remove-Item $InstallDir -Recurse -Force
    }
    New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
    Expand-Archive -Path $PayloadZip -DestinationPath $InstallDir -Force
    New-Item -ItemType Directory -Path (Join-Path $DataDir 'logs') -Force | Out-Null
    $script:AppCreatedThisRun = $true
    Write-InstallState 'in_progress' 'Application files copied'
    Write-Ok 'Da chep source ung dung sach.'
}

function Grant-RuntimeDataAccess {
    try {
        & icacls.exe $DataDir /grant '*S-1-5-32-545:(OI)(CI)M' /T /C | Out-Null
        Write-Ok 'Da cap quyen ghi runtime cho nguoi dung Windows.'
    }
    catch { Write-Warn 'Khong cap duoc quyen runtime tu dong.' }
}

function Write-AppEnv {
    $secret = New-SecretKey
    $envText = @"
DB_SETUP_VERSION=2
SECRET_KEY=$secret
DB_HOST=127.0.0.1
DB_PORT=$DbPort
DB_NAME=$DbName
DB_USER=$DbUser
DB_PASSWORD=$($script:DbAppPassword)
APP_HOST=0.0.0.0
APP_PORT=$AppPort
APP_DEBUG=0
"@
    Set-Content -Path (Join-Path $InstallDir '.env') -Value $envText -Encoding ASCII
}

function Test-OfflineRuntimePreflight([string]$PythonExe) {
    Write-Step 'Preflight Python + goi thu vien OFFLINE (chua tao database)...'
    if (-not (Test-Path $DepsZip)) { throw "Thieu goi thu vien offline: $DepsZip" }
    if (-not (Test-Path $VerifyRuntimePy)) { throw "Thieu script kiem tra runtime: $VerifyRuntimePy" }

    # Khong tao venv trong %TEMP% vi TEMP co the nam sau junction/redirect tren mot so may Windows.
    $preflightRoot = Join-Path $DataDir 'preflight'
    $preflight = Join-Path $preflightRoot ("venv_" + $PID)
    try {
        New-Item -ItemType Directory -Path $preflightRoot -Force | Out-Null
        if (Test-Path $preflight) { Remove-Item $preflight -Recurse -Force -ErrorAction SilentlyContinue }

        $rc = Invoke-NativeLogged -FilePath $PythonExe -Arguments @('-m','venv',$preflight)
        if ($rc -ne 0) { throw "Preflight: khong tao duoc venv (exit $rc)." }

        $py = Join-Path $preflight 'Scripts\python.exe'
        $site = Join-Path $preflight 'Lib\site-packages'
        if (-not (Test-Path $py)) { throw 'Preflight: khong tim thay python.exe trong venv.' }
        if (-not (Test-Path $site)) { New-Item -ItemType Directory -Path $site -Force | Out-Null }
        Expand-Archive -Path $DepsZip -DestinationPath $site -Force

        $rc = Invoke-NativeLogged -FilePath $py -Arguments @($VerifyRuntimePy)
        if ($rc -ne 0) { throw "Preflight: goi thu vien offline khong hoat dong (exit $rc)." }
        Write-Ok 'Preflight Python/runtime offline thanh cong. Chua thay doi database.'
    }
    finally {
        Remove-Item $preflight -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Prepare-PythonRuntime([string]$PythonExe) {
    Write-Step 'Tao Python virtual environment va nap thu vien OFFLINE...'
    if (-not (Test-Path $DepsZip)) { throw "Thieu goi thu vien offline: $DepsZip" }
    if (-not (Test-Path $VerifyRuntimePy)) { throw "Thieu script kiem tra runtime: $VerifyRuntimePy" }

    $venv = Join-Path $InstallDir '.venv'
    if (Test-Path $venv) { Remove-Item $venv -Recurse -Force -ErrorAction SilentlyContinue }

    $rc = Invoke-NativeLogged -FilePath $PythonExe -Arguments @('-m','venv',$venv)
    if ($rc -ne 0) { throw "Khong tao duoc .venv (exit $rc)." }

    $venvPy = Join-Path $venv 'Scripts\python.exe'
    if (-not (Test-Path $venvPy)) { throw "Khong tim thay $venvPy sau khi tao venv." }

    $site = Join-Path $venv 'Lib\site-packages'
    if (-not (Test-Path $site)) { New-Item -ItemType Directory -Path $site -Force | Out-Null }
    Expand-Archive -Path $DepsZip -DestinationPath $site -Force

    # Khong dung python -c: Windows PowerShell 5.1 co the lam mat dau nhay trong chuoi -c.
    $rc = Invoke-NativeLogged -FilePath $venvPy -Arguments @($VerifyRuntimePy)
    if ($rc -ne 0) { throw "Kiem tra thu vien Python offline that bai (exit $rc)." }

    Write-Ok 'Python runtime offline da san sang.'
    return $venvPy
}

function Initialize-AppDatabase([string]$VenvPython) {
    Write-Step "Khoi tao bang MariaDB va du lieu ban dau ($($script:DataMode))..."
    $oldPythonPath = $env:PYTHONPATH
    $oldDataMode = $env:ITSM_DATA_MODE
    Push-Location $InstallDir
    try {
        # Bao dam bootstrap trong installer import duoc module ITSM tu InstallDir.
        $env:PYTHONPATH = $InstallDir
        $env:ITSM_DATA_MODE = $script:DataMode
        $rc = Invoke-NativeLogged -FilePath $VenvPython -Arguments @($BootstrapPy)
        if ($rc -ne 0) { throw "Khoi tao schema ung dung that bai (exit $rc)." }
    }
    finally {
        $env:PYTHONPATH = $oldPythonPath
        $env:ITSM_DATA_MODE = $oldDataMode
        Pop-Location
    }
    Write-Ok "Database ung dung da san sang - che do: $($script:DataMode)."
}

function Create-FirstAdmin([string]$VenvPython) {
    Write-Step 'Tao tai khoan Admin dau tien...'
    $name = Read-Host 'Ho ten Admin [Quan tri vien]'
    if ([string]::IsNullOrWhiteSpace($name)) { $name = 'Quan tri vien' }
    while ($true) {
        $username = Read-Host 'Username Admin [admin]'
        if ([string]::IsNullOrWhiteSpace($username)) { $username = 'admin' }
        $reservedDemoUsers = @('tech01','tech02','user01','user02','user03','user04','user05')
        if ($script:DataMode -eq 'demo' -and $reservedDemoUsers -contains $username.ToLowerInvariant()) {
            Write-Warn "Username '$username' dang duoc dung cho tai khoan demo. Hay chon username Admin khac."
            continue
        }
        break
    }
    while ($true) {
        $s1 = Read-Host 'Mat khau Admin (toi thieu 8 ky tu)' -AsSecureString
        $p1 = Convert-SecureToPlain $s1
        if ($p1.Length -lt 8) { Write-Warn 'Mat khau phai co it nhat 8 ky tu.'; $p1=$null; continue }
        $s2 = Read-Host 'Nhap lai mat khau Admin' -AsSecureString
        $p2 = Convert-SecureToPlain $s2
        if ($p1 -ne $p2) { Write-Warn 'Hai mat khau khong giong nhau.'; $p1=$null; $p2=$null; continue }
        break
    }

    # Khong truyen password tren command line. Python doc qua environment cua child process.
    $env:ITSM_ADMIN_USERNAME = $username
    $env:ITSM_ADMIN_PASSWORD = $p1
    $env:ITSM_ADMIN_NAME = $name
    $env:PYTHONUTF8 = '1'
    $env:PYTHONIOENCODING = 'utf-8'

    $outFile = Join-Path $env:TEMP ("ITSM_Admin_" + $PID + ".out")
    $errFile = Join-Path $env:TEMP ("ITSM_Admin_" + $PID + ".err")
    $adminHelper = Join-Path $InstallDir '_create_first_admin_setup.py'
    Push-Location $InstallDir
    try {
        Remove-Item $outFile,$errFile,$adminHelper -Force -ErrorAction SilentlyContinue
        Copy-Item -Path $CreateFirstAdminPy -Destination $adminHelper -Force
        # Chay helper tu C:\ITSMService de khong bi anh huong boi duong dan Setup co khoang trang.
        $proc = Start-Process -FilePath $VenvPython -ArgumentList @('_create_first_admin_setup.py') -WorkingDirectory $InstallDir -NoNewWindow -Wait -PassThru -RedirectStandardOutput $outFile -RedirectStandardError $errFile
        if (Test-Path $outFile) { Get-Content $outFile -Encoding UTF8 | ForEach-Object { Write-Host $_ } }
        if (Test-Path $errFile) { Get-Content $errFile -Encoding UTF8 | ForEach-Object { Write-Host $_ -ForegroundColor Red } }
        if ($proc.ExitCode -ne 0) { throw "Tao Admin that bai (exit $($proc.ExitCode)). Xem log loi o tren." }
    }
    finally {
        Pop-Location
        Remove-Item $outFile,$errFile,$adminHelper -Force -ErrorAction SilentlyContinue
        $env:ITSM_ADMIN_USERNAME = $null
        $env:ITSM_ADMIN_PASSWORD = $null
        $env:ITSM_ADMIN_NAME = $null
        $p1=$null; $p2=$null
    }
    Write-Ok "Da tao Admin: $username"
    return $username
}

function Save-InstallInfo([string]$AdminUser) {
    $demoInfo = ''
    if ($script:DataMode -eq 'demo') {
        $demoInfo = @"

TAI KHOAN DEMO
Technical: tech01 / Demo@123
Technical: tech02 / Demo@123
User: user01, user02, user03, user04, user05 / Demo@123
"@
    }
    $content = @"
ITSM V1.5 - THONG TIN QUAN TRI
Ngay cai: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
Thu muc: $InstallDir
Web: http://127.0.0.1:$AppPort
Database: $DbName
DB App User: $DbUser
DB App Password: $($script:DbAppPassword)
Admin ung dung: $AdminUser
Du lieu ban dau: $($script:DataMode)$demoInfo

MariaDB root password xem tai:
$RecoveryFile
"@
    Set-Content -Path $InstallInfoFile -Value $content -Encoding UTF8
    Protect-SecretFile $InstallInfoFile
}

function Create-Shortcuts {
    Write-Step 'Tao shortcut va mo Firewall LAN...'
    $shell = New-Object -ComObject WScript.Shell
    $desktop = [Environment]::GetFolderPath('CommonDesktopDirectory')
    $lnk = $shell.CreateShortcut((Join-Path $desktop 'ITSM.lnk'))
    $lnk.TargetPath = Join-Path $env:WINDIR 'System32\wscript.exe'
    $lnk.Arguments = '"' + (Join-Path $InstallDir 'run_windows.vbs') + '"'
    $lnk.WorkingDirectory = $InstallDir
    $lnk.Description = 'Mo ITSM V1.5'
    $lnk.Save()
    try {
        $existing = Get-NetFirewallRule -DisplayName 'ITSM Web' -ErrorAction SilentlyContinue
        if ($existing) { Remove-NetFirewallRule -DisplayName 'ITSM Web' -ErrorAction SilentlyContinue }
        New-NetFirewallRule -DisplayName 'ITSM Web' -Direction Inbound -Action Allow -Protocol TCP -LocalPort $AppPort -Profile Domain,Private | Out-Null
        Write-Ok 'Da tao shortcut Desktop va Firewall port 8088.'
    }
    catch { Write-Warn 'Da tao shortcut, nhung khong tu mo duoc Firewall port 8088.' }
}

function Rollback-CurrentInstall {
    if ($script:DbCreatedThisRun -or $script:DbUserCreatedThisRun) {
        Write-Step 'Rollback database cua lan cai dat dang do...'
        Remove-AppDatabaseAndUser $script:MariaCliForRollback
    }
    if ($script:AppCreatedThisRun -and (Test-Path $InstallDir)) {
        Stop-OldITSM
        Remove-Item $InstallDir -Recurse -Force -ErrorAction SilentlyContinue
        Write-Ok 'Da go thu muc app dang do.'
    }
    $script:DbCreatedThisRun = $false
    $script:DbUserCreatedThisRun = $false
    $script:AppCreatedThisRun = $false
    Write-InstallState 'failed_rolled_back' 'Setup failed; DB/user/app rollback attempted'
}

try {
    if (-not (Test-Admin)) { throw 'Setup phai chay bang quyen Administrator.' }
    Confirm-InstallerPassword
    if (-not (Test-Path $PayloadZip)) { throw "Thieu payload: $PayloadZip" }
    if (-not (Test-Path $DepsZip)) { throw "Thieu thu vien offline: $DepsZip" }
    if (-not (Test-Path $BootstrapPy)) { throw "Thieu bootstrap: $BootstrapPy" }
    if (-not (Test-Path $VerifyRuntimePy)) { throw "Thieu verify runtime: $VerifyRuntimePy" }

    Write-Step 'Kiem tra tinh toan ven bo cai ITSM V1.5...'
    Assert-FileSha256 $PayloadZip $PayloadSha256 'app_payload.zip'
    Assert-FileSha256 $DepsZip $DepsSha256 'python_site_packages_cp313_win_amd64.zip'
    Assert-FileSha256 $BootstrapPy $BootstrapSha256 'bootstrap_clean_db.py'
    Assert-FileSha256 $VerifyRuntimePy $VerifyRuntimeSha256 'verify_runtime.py'
    Assert-FileSha256 $CreateFirstAdminPy $CreateFirstAdminSha256 'create_first_admin.py'

    New-Item -ItemType Directory -Path $DataDir -Force | Out-Null

    Write-Step 'Kiem tra MariaDB...'
    $mariaCli = Find-MariaCli
    $svc = Get-MariaService

    # Legacy failed installer recovery: MariaDB exists + app/data traces + no success/recovery info.
    $legacyPartial = $false  # ITSM R2 khong co legacy one-click installer can recovery bang GOMARIADB
    if ($legacyPartial) {
        $removed = Remove-LegacyPartialMariaDb
        if ($removed) { $mariaCli=$null; $svc=$null }
    }

    if (-not $mariaCli -or -not $svc) {
        Install-MariaDbLocal
        $mariaCli = Find-MariaCli
        $svc = Get-MariaService
        if (-not $mariaCli -or -not $svc) { throw 'Khong tim thay MariaDB sau khi cai local.' }
    }
    else {
        if ($svc.Status -ne 'Running') { Start-Service -Name $svc.Name; Start-Sleep -Seconds 2 }
        Write-Ok "Da co MariaDB: $($svc.Name)"
    }

    $script:MariaCliForRollback = $mariaCli
    Ensure-MariaRootAccess $mariaCli
    Resolve-PartialFromFixedSetup $mariaCli
    Write-InstallState 'in_progress' 'MariaDB ready; no application database created yet'

    # Kiem tra Python/runtime TRUOC KHI tao/xoa database de tranh rollback khong can thiet.
    Write-Step 'Kiem tra Python 3.13...'
    $python = Find-Python313
    if (-not $python) { $python = Install-Python313Local }
    else { Write-Ok "Da co Python 3.13: $python" }
    Test-OfflineRuntimePreflight $python
    Select-InitialDataMode

    Prepare-CleanDatabase $mariaCli
    Install-AppFiles
    Grant-RuntimeDataAccess
    Write-AppEnv
    $venvPython = Prepare-PythonRuntime $python
    Initialize-AppDatabase $venvPython
    $adminUser = Create-FirstAdmin $venvPython
    Save-InstallInfo $adminUser
    Create-Shortcuts

    Set-Content -Path $InstallOkFlag -Value "OK $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') V$ProductVersion" -Encoding ASCII
    Write-InstallState 'complete' 'Installation completed successfully'

    Write-Step 'Khoi dong ITSM...'
    Start-Process -FilePath (Join-Path $env:WINDIR 'System32\wscript.exe') -ArgumentList @(('"{0}"' -f (Join-Path $InstallDir 'run_windows.vbs'))) -WorkingDirectory $InstallDir

    Write-Host ''
    Write-Host '============================================================' -ForegroundColor Green
    Write-Host '             CAI DAT ITSM THANH CONG' -ForegroundColor Green
    Write-Host "             Build: $BuildId" -ForegroundColor Green
    Write-Host '============================================================' -ForegroundColor Green
    Write-Host "Web tren may nay : http://127.0.0.1:$AppPort"
    Write-Host "Thu muc ung dung : $InstallDir"
    Write-Host "Tai khoan Admin  : $adminUser"
    Write-Host "Du lieu ban dau  : $($script:DataMode)"
    if ($script:DataMode -eq 'demo') {
        Write-Host 'Demo Technical    : tech01, tech02 / Demo@123' -ForegroundColor Yellow
        Write-Host 'Demo User         : user01..user05 / Demo@123' -ForegroundColor Yellow
    }
    Write-Host 'Shortcut          : ITSM tren Desktop'
    Write-Host "Recovery MariaDB  : $RecoveryFile" -ForegroundColor Yellow
    Pause-End
    exit 0
}
catch {
    Write-Host ''
    Write-Host '==================== CAI DAT THAT BAI ====================' -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red
    try { Rollback-CurrentInstall } catch { Write-Warn "Rollback gap loi: $($_.Exception.Message)" }
    Write-Host 'Database/user/app duoc tao trong LAN CAI NAY se duoc rollback neu co the.' -ForegroundColor Yellow
    Write-Host 'MariaDB/Python da cai se duoc GIU LAI de chay Setup lai nhanh hon.' -ForegroundColor Yellow
    Pause-End
    exit 1
}
finally {
    $env:MYSQL_PWD = $null
}
