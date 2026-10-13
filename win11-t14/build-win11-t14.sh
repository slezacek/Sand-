#!/usr/bin/env bash
# Postaví Windows 11 médium pro ThinkPad T14 Gen 3 (Intel), které se nainstaluje samo:
# smaže disk 0, nainstaluje Windows 11 Home, nahraje Lenovo drivery a pokusí se o
# aktivaci firmwarovým klíčem. Běží na Linuxu i na macOS, potřebuje internet.
#
#   ./build-win11-t14.sh --usb auto     -> zapíše rovnou bootovací flešku (doporučeno)
#   ./build-win11-t14.sh                -> vyrobí win11-t14-auto.iso
#
# Originální Windows 11 ISO si stáhni z microsoft.com/software-download/windows11
# (do Stažených/Downloads, skript si ho najde sám, nebo ho zadej přes --win-iso).
set -euo pipefail

OS=$(uname -s)
ISO_IN=""; OUT_ISO="$PWD/win11-t14-auto.iso"; USB=""; EDITION="Home"
WIN_USER=""; WIN_PASS="${WIN_PASSWORD:-}"; PC_NAME="T14-G3"
LOCALE="cs-CZ"; KBD="0405:00000405"; TZ_WIN="Central Europe Standard Time"
MTYPE=""; PACK=""; SKIP_DRIVERS=0; FORCE=0
WORK="${WORK_DIR:-/var/tmp/win11-t14-build}"
SPLIT_MB="${SPLIT_MB:-3800}"
CATALOG_URL="${LENOVO_CATALOG:-https://download.lenovo.com/cdrt/td/catalogv2.xml}"

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31mCHYBA:\033[0m %s\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }
lc() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

usage() {
  cat <<'EOF'
Použití: ./build-win11-t14.sh [volby]
  --usb auto|ZAŘÍZENÍ  zapsat rovnou na flešku (smaže ji); auto = jediný externí disk
  --win-iso SOUBOR     originální Windows 11 ISO (jinak se hledá ve Stažených)
  --out SOUBOR         výstupní ISO (výchozí ./win11-t14-auto.iso)
  --edition Home|Pro   edice Windows (výchozí Home)
  --user JMENO         jméno lokálního účtu (výchozí jméno přihlášeného uživatele)
  --password HESLO     heslo účtu (výchozí prázdné; lze i proměnnou WIN_PASSWORD)
  --pc-name NAZEV      název počítače (výchozí T14-G3)
  --type 21AH          typ stroje pro výběr driveru (výchozí 21AH = T14 Gen 3 Intel)
  --driver-pack CESTA  driver pack od Lenovo (.exe nebo rozbalená složka)
  --no-drivers         nevkládat Lenovo drivery
  --force              povolit zápis i na disk, který nevypadá jako externí
EOF
}

while (($#)); do
  case $1 in
    --win-iso) ISO_IN=$2; shift 2 ;;
    --out) OUT_ISO=$2; shift 2 ;;
    --usb) USB=$2; shift 2 ;;
    --edition) EDITION=$2; shift 2 ;;
    --user) WIN_USER=$2; shift 2 ;;
    --password) WIN_PASS=$2; shift 2 ;;
    --pc-name) PC_NAME=$2; shift 2 ;;
    --type) MTYPE=$2; shift 2 ;;
    --driver-pack) PACK=$2; shift 2 ;;
    --no-drivers) SKIP_DRIVERS=1; shift ;;
    --force) FORCE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage; die "neznámá volba: $1" ;;
  esac
done

SUDO=""
case $OS in
  Linux)  [[ $EUID -eq 0 ]] || exec sudo -E "$0" "$@" ;;
  Darwin) [[ $EUID -eq 0 ]] || SUDO=sudo ;;
  *) die "podporuji jen Linux a macOS" ;;
esac

case $(lc "$EDITION") in
  pro)  EDITION=Pro;  WIN_KEY="VK7JG-NPHTM-C97JM-9MPGT-3V66T" ;;
  home) EDITION=Home; WIN_KEY="YTMG3-N6DKC-DKB77-7M9GH-8HVX7" ;;
  *) die "edice musí být Home nebo Pro" ;;
esac
IMAGE_NAME="Windows 11 $EDITION"

# --- závislosti -------------------------------------------------------------
need=()
add_dep() { if [[ $OS == Linux ]]; then need+=("$1"); else need+=("$2"); fi; }
SZ=$(command -v 7z || command -v 7zz || true)
[[ -n $SZ ]] || add_dep p7zip-full sevenzip
have wimlib-imagex || add_dep wimtools wimlib
have xorriso || add_dep xorriso xorriso
have innoextract || add_dep innoextract innoextract
have curl || add_dep curl curl
python3 -c 'import sys' >/dev/null 2>&1 || add_dep python3 python
if [[ $OS == Linux ]]; then
  have rsync || need+=(rsync)
  have parted || need+=(parted)
  have mkfs.vfat || need+=(dosfstools)
fi
if ((${#need[@]})); then
  log "Instaluji: ${need[*]}"
  if [[ $OS == Linux ]]; then
    have apt-get || die "chybí ${need[*]} a není apt-get"
    apt-get update -qq && apt-get install -y -qq "${need[@]}"
  else
    have brew || die "chybí ${need[*]}; nainstaluj Homebrew (https://brew.sh) a spusť skript znovu"
    brew install "${need[@]}"
  fi
  SZ=$(command -v 7z || command -v 7zz || true)
  [[ -n $SZ ]] || die "7-Zip se nenainstaloval"
fi

# --- pomocné skripty v Pythonu ----------------------------------------------------
mkdir -p "$WORK/cache" "$WORK/py"
PY="$WORK/py"

cat > "$PY/find_iso.py" <<'PYEOF'
import os, sys
best = None
for root in sys.argv[1:]:
    if not os.path.isdir(root):
        continue
    base = root.rstrip('/').count('/')
    for d, dirs, files in os.walk(root):
        if d.count('/') - base >= 3:
            dirs[:] = []
        for f in files:
            n = f.lower()
            if n.endswith('.iso') and 'win' in n and '11' in n:
                p = os.path.join(d, f)
                try:
                    s = os.path.getsize(p)
                except OSError:
                    continue
                if s > 3 * 1024 ** 3 and (best is None or s > best[0]):
                    best = (s, p)
if best:
    print(best[1])
PYEOF

cat > "$PY/pick_pack.py" <<'PYEOF'
import re, sys, xml.etree.ElementTree as ET
path, mt = sys.argv[1], sys.argv[2].upper()
tag = lambda e: e.tag.split('}')[-1].lower()
best = None
for model in ET.parse(path).getroot().iter():
    if tag(model) != 'model':
        continue
    types = [(t.text or '').strip().upper() for t in model.iter() if tag(t) == 'type']
    if mt not in types:
        continue
    for s in model.iter():
        if tag(s) != 'sccm':
            continue
        url = (s.text or '').strip()
        osn = (s.get('os') or '').lower()
        if not url or not ('11' in osn or re.search(r'w(in)?11', url.lower())):
            continue
        if 'winpe' in osn or 'winpe' in url.lower():
            continue  # balík jen pro Windows PE: bez videa a touchpadu
        m = re.match(r'(\d{2})H(\d)', (s.get('version') or '').upper())
        key = ((int(m.group(1)), int(m.group(2))) if m else (0, 0), s.get('date') or '', url)
        if best is None or key > best:
            best = key
    if best is None:
        blob = ET.tostring(model, encoding='unicode')
        urls = [u for u in re.findall(r'https://download\.lenovo\.com/[^\s<>"]+\.exe', blob)
                if re.search(r'w(in)?11', u.lower())]
        if urls:
            best = ((0, 0), '', max(urls))
if best:
    print(best[2])
PYEOF

cat > "$PY/winpe_dirs.py" <<'PYEOF'
import os, re, shutil, sys
src, dst = sys.argv[1], sys.argv[2]
SERIALIO = re.compile(r'i2c|gpio|serial\s*io|lpss', re.I)
dirs, display, touch, serialio = set(), 0, 0, 0
for d, _, files in os.walk(src):
    for f in files:
        if not f.lower().endswith('.inf'):
            continue
        raw = open(os.path.join(d, f), 'rb').read()
        if raw[:2] in (b'\xff\xfe', b'\xfe\xff'):
            text = raw.decode('utf-16', 'ignore')
        else:
            text = raw.decode('utf-8-sig', 'ignore')
        m = re.search(r'^\s*Class\s*=\s*([A-Za-z0-9_]+)', text, re.I | re.M)
        cls = m.group(1).lower() if m else ''
        is_sio = cls == 'system' and bool(SERIALIO.search(f + text))
        if cls == 'display':
            display += 1
        if cls in ('mouse', 'hidclass'):
            touch += 1
        if is_sio:
            serialio += 1
        # do instalátoru (WinPE): úložiště, síť, vstupní zařízení a Serial IO (bez něj trackpad nejede)
        if cls in ('scsiadapter', 'hdc', 'net', 'mouse', 'keyboard', 'hidclass') or is_sio:
            dirs.add(d)
for n, d in enumerate(sorted(dirs)):
    shutil.copytree(d, os.path.join(dst, '%03d_%s' % (n, os.path.basename(d))), dirs_exist_ok=True)
print('WinPE driver složek: %d | v packu: video=%d, trackpad/myš=%d, Serial IO=%d' % (len(dirs), display, touch, serialio))
for name, cnt in (('video (Display)', display), ('trackpad/myš (Mouse/HIDClass)', touch), ('Intel Serial IO (I2C)', serialio)):
    if cnt == 0:
        print('\033[1;33mVAROVÁNÍ:\033[0m v driver packu nejsou INF drivery pro %s, po instalaci to může chybět' % name)
PYEOF

cat > "$PY/render.py" <<'PYEOF'
import os, sys
from xml.sax.saxutils import escape
e = os.environ
pw = e['WPASS']
def pwblock(indent):
    if not pw:
        return ''
    i = ' ' * indent
    return ('%s<Password>\n%s  <Value>%s</Value>\n%s  <PlainText>true</PlainText>\n%s</Password>\n'
            % (i, i, escape(pw), i, i))
text = open(sys.argv[1], encoding='utf-8').read()
pnp = ''
if e.get('HAVE_INF') == '1':
    pnp = ('    <component name="Microsoft-Windows-PnpCustomizationsNonWinPE" processorArchitecture="amd64" '
           'publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" '
           'xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" '
           'xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">\n'
           '      <DriverPaths>\n'
           '        <PathAndCredentials wcm:action="add" wcm:keyValue="1">\n'
           '          <Path>C:\\Drivers\\Lenovo</Path>\n'
           '        </PathAndCredentials>\n'
           '      </DriverPaths>\n'
           '    </component>\n')
text = text.replace('@PNP@\n', pnp)
text = text.replace('@ACCT_PW@\n', pwblock(12)).replace('@AUTO_PW@\n', pwblock(8))
vals = {'UILANG': e['UILANG'], 'KBD': e['KBD'], 'LOCALE': e['LOCALE'], 'TZ': e['TZW'],
        'PCNAME': e['PCNAME'], 'KEY': e['KEY'], 'USER': e['WUSER']}
for k, v in vals.items():
    text = text.replace('@%s@' % k, escape(v))
open(sys.argv[2], 'w', encoding='utf-8').write(text)
PYEOF

cat > "$PY/plist_get.py" <<'PYEOF'
import plistlib, sys
d = plistlib.loads(sys.stdin.buffer.read())
print(d.get(sys.argv[1], ''))
PYEOF

# --- vstupy -------------------------------------------------------------------
if [[ -z $ISO_IN ]]; then
  ISO_IN=$(python3 "$PY/find_iso.py" /home /root /Users /media /mnt /Volumes "$PWD" || true)
  [[ -n $ISO_IN ]] || die "nenašel jsem Windows 11 ISO. Stáhni ho z microsoft.com/software-download/windows11 a spusť znovu (nebo použij --win-iso)."
fi
[[ -f $ISO_IN ]] || die "ISO neexistuje: $ISO_IN"
log "Zdrojové ISO: $ISO_IN"

if [[ -z $WIN_USER ]]; then
  WIN_USER=$(printf '%s' "${SUDO_USER:-${USER:-}}" | tr -cd 'A-Za-z0-9._-')
fi
case $(lc "$WIN_USER") in
  ""|root|admin|administrator|guest|system) WIN_USER=uzivatel ;;
esac

mac_prop() { diskutil info -plist "$1" | python3 "$PY/plist_get.py" "$2"; }

if [[ $USB == auto ]]; then
  if [[ $OS == Darwin ]]; then
    cand=$(diskutil list external physical | awk '/^\/dev\/disk[0-9]+ /{print $1}')
  else
    cand=$(lsblk -dnpo NAME,TRAN | awk '$2=="usb"{print $1}')
  fi
  [[ -n $cand ]] || die "nenašel jsem žádnou externí/USB flešku. Zasuň ji a spusť znovu."
  [[ $(printf '%s\n' "$cand" | wc -l) -eq 1 ]] || die "našel jsem víc externích disků ($(echo $cand)); zadej správný přes --usb"
  USB=$cand
  log "Vybraná fleška: $USB"
fi

if [[ -n $USB ]]; then
  if [[ $OS == Darwin ]]; then
    [[ $(mac_prop "$USB" WholeDisk) == True ]] || die "$USB není celý disk (zadej např. /dev/disk4, ne /dev/disk4s1)"
    if [[ $(mac_prop "$USB" Internal) != False && $FORCE -ne 1 ]]; then
      die "$USB je interní disk, odmítám. Pokud to opravdu chceš, přidej --force."
    fi
  else
    [[ -b $USB ]] || die "$USB není blokové zařízení"
    tran=$(lsblk -dno TRAN "$USB" 2>/dev/null || true)
    if [[ $tran != usb && $FORCE -ne 1 ]]; then
      die "$USB nevypadá jako USB disk (TRAN='$tran'). Pokud to opravdu chceš, přidej --force."
    fi
    if lsblk -nro MOUNTPOINT "$USB" | grep -qE '^(/|/boot|/boot/efi|/home)$'; then
      die "$USB obsahuje systémové oddíly tohoto počítače, odmítám"
    fi
  fi
fi

if [[ -z $MTYPE ]]; then
  MTYPE=21AH
  if [[ -r /sys/class/dmi/id/sys_vendor && -r /sys/class/dmi/id/product_name ]]; then
    case $(lc "$(cat /sys/class/dmi/id/sys_vendor)") in
      *lenovo*) pname=$(cat /sys/class/dmi/id/product_name); MTYPE=${pname:0:4} ;;
    esac
  fi
fi
log "Nastavení: $IMAGE_NAME, účet '$WIN_USER', $([[ -n $WIN_PASS ]] && echo 'heslo nastaveno' || echo 'bez hesla'), typ stroje $MTYPE"

X="$WORK/tree"
rm -rf "$X"; mkdir -p "$X"
trap 'rm -rf "$X" "$WORK/single.wim"' EXIT

avail_kb=$(df -Pk "$WORK" | awk 'NR==2{print $4}')
((avail_kb > 28*1024*1024)) || die "v $WORK je málo místa (potřeba ~28 GB, WORK_DIR jde změnit)"

# --- rozbalení Windows ISO ------------------------------------------------------
log "Rozbaluji Windows ISO (pár minut)"
"$SZ" x -y -bd -o"$X" "$ISO_IN" >/dev/null || die "rozbalení ISO selhalo"
rm -rf "$X/[BOOT]"
for f in boot/etfsboot.com efi/boot/bootx64.efi efi/microsoft/boot/efisys.bin sources/boot.wim; do
  [[ -f $X/$f ]] || die "v ISO chybí $f, tohle nevypadá jako instalační ISO Windows 11 x64"
done
[[ -f $X/sources/install.wim ]] || die "ISO neobsahuje sources/install.wim (install.esd nepodporuji), stáhni ISO přímo z microsoft.com"

# --- vybrat edici a připravit install.wim ---------------------------------------
idx=$(wimlib-imagex info "$X/sources/install.wim" | awk -v n="$IMAGE_NAME" '
  /^Index:/ {i=$2}
  /^Name:/ { sub(/^Name:[ \t]*/,""); if ($0==n) {print i; exit} }')
[[ -n $idx ]] || die "v ISO není edice '$IMAGE_NAME'"
UI_LANG=$(wimlib-imagex info "$X/sources/install.wim" "$idx" | awk -F': *' '/^Default Language:/ {print $2; exit}')
UI_LANG=${UI_LANG:-en-US}
log "Edice: $IMAGE_NAME (image $idx), jazyk instalátoru: $UI_LANG"

log "Extrahuji vybranou edici"
wimlib-imagex export "$X/sources/install.wim" "$idx" "$WORK/single.wim" >/dev/null
rm -f "$X/sources/install.wim"
size=$(wc -c < "$WORK/single.wim")
if ((size > SPLIT_MB*1024*1024)); then
  log "Dělím install.wim na části po ${SPLIT_MB} MB (kvůli FAT32/ISO9660)"
  wimlib-imagex split "$WORK/single.wim" "$X/sources/install.swm" "$SPLIT_MB" >/dev/null
  rm -f "$WORK/single.wim"
else
  mv "$WORK/single.wim" "$X/sources/install.wim"
fi

# --- Lenovo drivery ---------------------------------------------------------------
OEM="$X/sources/\$OEM\$/\$1/Drivers"
mkdir -p "$OEM"
HAVE_INF=0
if ((SKIP_DRIVERS == 0)); then
  if [[ -z $PACK ]]; then
    log "Hledám driver pack pro typ $MTYPE v katalogu Lenovo"
    curl -fsSL --retry 3 "$CATALOG_URL" -o "$WORK/cache/catalog.xml" \
      || die "nepodařilo se stáhnout katalog Lenovo ($CATALOG_URL); stáhni pack ručně a použij --driver-pack"
    url=$(python3 "$PY/pick_pack.py" "$WORK/cache/catalog.xml" "$MTYPE" || true)
    [[ -n $url ]] || die "v katalogu Lenovo není driver pack pro Windows 11 a typ $MTYPE; stáhni ho ručně z pcsupport.lenovo.com a použij --driver-pack"
    PACK="$WORK/cache/$(basename "$url")"
    if [[ -s $PACK ]]; then
      log "Driver pack už je stažený: $PACK"
    else
      log "Stahuji $url"
      curl -fL --retry 5 -C - -o "$PACK.part" "$url" \
        || { rm -f "$PACK.part"; curl -fL --retry 5 -o "$PACK.part" "$url"; } \
        || die "stažení driver packu selhalo"
      mv "$PACK.part" "$PACK"
    fi
  fi

  log "Připravuji drivery"
  DRV="$WORK/cache/drivers"
  rm -rf "$DRV"; mkdir -p "$DRV"
  if [[ -d $PACK ]]; then
    cp -a "$PACK/." "$DRV/"
  else
    innoextract -q -d "$DRV" "$PACK" >/dev/null 2>&1 || "$SZ" x -y -bd -o"$DRV" "$PACK" >/dev/null 2>&1 || true
  fi
  ninf=$(find "$DRV" -type f -iname '*.inf' | wc -l)
  if ((ninf > 0)); then
    log "Nalezeno $ninf souborů .inf"
    cp -a "$DRV" "$OEM/Lenovo"
    HAVE_INF=1
    python3 "$PY/winpe_dirs.py" "$DRV" "$X/\$WinPEDriver\$"
  else
    log "Pack se nepodařilo rozbalit, nainstaluje se tichým spuštěním ve Windows"
    cp "$PACK" "$OEM/LenovoPack.exe"
  fi
fi

# --- skripty a odpovědní soubor ------------------------------------------------------
crlf() { awk '{ printf "%s\r\n", $0 }' "$1" > "$1.tmp" && mv "$1.tmp" "$1"; }

cat > "$OEM/finish.cmd" <<'EOF'
@echo off
set LOG=C:\Drivers\finish.log
echo [%date% %time%] start >> %LOG%
if exist C:\Drivers\LenovoPack.exe C:\Drivers\LenovoPack.exe /VERYSILENT /SUPPRESSMSGBOXES /NORESTART /DIR=C:\Drivers\Lenovo >> %LOG% 2>&1
if exist C:\Drivers\Lenovo\ pnputil /add-driver C:\Drivers\Lenovo\*.inf /subdirs /install >> %LOG% 2>&1
powershell -NoProfile -ExecutionPolicy Bypass -File C:\Drivers\activate.ps1 >> %LOG% 2>&1
echo [%date% %time%] hotovo >> %LOG%
shutdown /r /t 60 /c "Dokonceni instalace driveru"
EOF
crlf "$OEM/finish.cmd"

cat > "$OEM/activate.ps1" <<'EOF'
$k = (Get-CimInstance -ClassName SoftwareLicensingService).OA3xOriginalProductKey
if ($k) {
    cscript //nologo C:\Windows\System32\slmgr.vbs /ipk $k
    cscript //nologo C:\Windows\System32\slmgr.vbs /ato
}
EOF
crlf "$OEM/activate.ps1"

cat > "$WORK/autounattend.tpl" <<'EOF'
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend">
  <settings pass="windowsPE">
    <component name="Microsoft-Windows-International-Core-WinPE" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
      <SetupUILanguage>
        <UILanguage>@UILANG@</UILanguage>
      </SetupUILanguage>
      <InputLocale>@KBD@</InputLocale>
      <SystemLocale>@LOCALE@</SystemLocale>
      <UILanguage>@UILANG@</UILanguage>
      <UserLocale>@LOCALE@</UserLocale>
    </component>
    <component name="Microsoft-Windows-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
      <RunSynchronous>
        <RunSynchronousCommand wcm:action="add">
          <Order>1</Order>
          <Path>reg.exe add HKLM\SYSTEM\Setup\LabConfig /v BypassTPMCheck /t REG_DWORD /d 1 /f</Path>
        </RunSynchronousCommand>
        <RunSynchronousCommand wcm:action="add">
          <Order>2</Order>
          <Path>reg.exe add HKLM\SYSTEM\Setup\LabConfig /v BypassSecureBootCheck /t REG_DWORD /d 1 /f</Path>
        </RunSynchronousCommand>
      </RunSynchronous>
      <DynamicUpdate>
        <Enable>false</Enable>
        <WillShowUI>Never</WillShowUI>
      </DynamicUpdate>
      <DiskConfiguration>
        <WillShowUI>OnError</WillShowUI>
        <Disk wcm:action="add">
          <DiskID>0</DiskID>
          <WillWipeDisk>true</WillWipeDisk>
          <CreatePartitions>
            <CreatePartition wcm:action="add">
              <Order>1</Order>
              <Type>Primary</Type>
              <Size>1000</Size>
            </CreatePartition>
            <CreatePartition wcm:action="add">
              <Order>2</Order>
              <Type>EFI</Type>
              <Size>300</Size>
            </CreatePartition>
            <CreatePartition wcm:action="add">
              <Order>3</Order>
              <Type>MSR</Type>
              <Size>16</Size>
            </CreatePartition>
            <CreatePartition wcm:action="add">
              <Order>4</Order>
              <Type>Primary</Type>
              <Extend>true</Extend>
            </CreatePartition>
          </CreatePartitions>
          <ModifyPartitions>
            <ModifyPartition wcm:action="add">
              <Order>1</Order>
              <PartitionID>1</PartitionID>
              <Label>Windows RE tools</Label>
              <Format>NTFS</Format>
              <TypeID>DE94BBA4-06D1-4D40-A16A-BFD50179D6AC</TypeID>
            </ModifyPartition>
            <ModifyPartition wcm:action="add">
              <Order>2</Order>
              <PartitionID>2</PartitionID>
              <Label>System</Label>
              <Format>FAT32</Format>
            </ModifyPartition>
            <ModifyPartition wcm:action="add">
              <Order>3</Order>
              <PartitionID>3</PartitionID>
            </ModifyPartition>
            <ModifyPartition wcm:action="add">
              <Order>4</Order>
              <PartitionID>4</PartitionID>
              <Label>Windows</Label>
              <Letter>C</Letter>
              <Format>NTFS</Format>
            </ModifyPartition>
          </ModifyPartitions>
        </Disk>
      </DiskConfiguration>
      <ImageInstall>
        <OSImage>
          <InstallTo>
            <DiskID>0</DiskID>
            <PartitionID>4</PartitionID>
          </InstallTo>
          <WillShowUI>OnError</WillShowUI>
        </OSImage>
      </ImageInstall>
      <UserData>
        <AcceptEula>true</AcceptEula>
        <ProductKey>
          <Key>@KEY@</Key>
          <WillShowUI>OnError</WillShowUI>
        </ProductKey>
      </UserData>
    </component>
  </settings>
  <settings pass="specialize">
    <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
      <ComputerName>@PCNAME@</ComputerName>
      <TimeZone>@TZ@</TimeZone>
    </component>
    <component name="Microsoft-Windows-SecureStartup-FilterDriver" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
      <PreventDeviceEncryption>true</PreventDeviceEncryption>
    </component>
@PNP@
  </settings>
  <settings pass="oobeSystem">
    <component name="Microsoft-Windows-International-Core" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
      <InputLocale>@KBD@</InputLocale>
      <SystemLocale>@LOCALE@</SystemLocale>
      <UILanguage>@UILANG@</UILanguage>
      <UserLocale>@LOCALE@</UserLocale>
    </component>
    <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
      <UserAccounts>
        <LocalAccounts>
          <LocalAccount wcm:action="add">
            <Name>@USER@</Name>
            <DisplayName>@USER@</DisplayName>
            <Group>Administrators</Group>
@ACCT_PW@
          </LocalAccount>
        </LocalAccounts>
      </UserAccounts>
      <AutoLogon>
        <Username>@USER@</Username>
        <Enabled>true</Enabled>
        <LogonCount>1</LogonCount>
@AUTO_PW@
      </AutoLogon>
      <OOBE>
        <HideEULAPage>true</HideEULAPage>
        <HideOEMRegistrationScreen>true</HideOEMRegistrationScreen>
        <HideOnlineAccountScreens>true</HideOnlineAccountScreens>
        <HideWirelessSetupInOOBE>true</HideWirelessSetupInOOBE>
        <HideLocalAccountScreen>true</HideLocalAccountScreen>
        <ProtectYourPC>3</ProtectYourPC>
        <NetworkLocation>Work</NetworkLocation>
      </OOBE>
      <FirstLogonCommands>
        <SynchronousCommand wcm:action="add">
          <Order>1</Order>
          <CommandLine>cmd /c C:\Drivers\finish.cmd</CommandLine>
          <Description>Lenovo drivery a aktivace</Description>
        </SynchronousCommand>
      </FirstLogonCommands>
    </component>
  </settings>
</unattend>
EOF

UILANG="$UI_LANG" KBD="$KBD" LOCALE="$LOCALE" TZW="$TZ_WIN" PCNAME="$PC_NAME" \
KEY="$WIN_KEY" WUSER="$WIN_USER" WPASS="$WIN_PASS" HAVE_INF="$HAVE_INF" \
  python3 "$PY/render.py" "$WORK/autounattend.tpl" "$X/autounattend.xml"
rm -f "$WORK/autounattend.tpl"
WIN_PASS=""

# --- výstup -----------------------------------------------------------------------------
if [[ -n $USB ]]; then
  log "Zapisuji na $USB"
  if [[ $OS == Darwin ]]; then
    diskutil list "$USB" | head -8
  else
    lsblk -o NAME,SIZE,MODEL,TRAN "$USB"
  fi
  read -rp "Celý obsah $USB bude SMAZÁN. Pro potvrzení napiš ANO: " ans
  [[ $ans == ANO ]] || die "zrušeno"
  if [[ $OS == Darwin ]]; then
    $SUDO diskutil eraseDisk FAT32 WIN11AUTO GPT "$USB" >/dev/null
    mnt=$(mac_prop "${USB}s2" MountPoint)
    [[ -d $mnt ]] || die "flešku se nepodařilo připojit po formátování"
    log "Kopíruji soubory na flešku (10–20 minut, nic nedělej)"
    COPYFILE_DISABLE=1 cp -R "$X"/. "$mnt"/
    find "$mnt" -name '._*' -delete 2>/dev/null || true
    sync
    diskutil eject "$USB" >/dev/null || true
  else
    for p in $(lsblk -nrpo NAME "$USB" | tail -n +2); do umount "$p" 2>/dev/null || true; done
    wipefs -a "$USB" >/dev/null
    parted -s "$USB" mklabel gpt mkpart WIN11AUTO fat32 1MiB 100% set 1 msftdata on
    partprobe "$USB" || true
    if have udevadm; then udevadm settle || true; fi
    part=""
    for _ in $(seq 20); do
      part=$(lsblk -nlpo NAME,TYPE "$USB" | awk '$2=="part"{print $1; exit}')
      [[ -n $part && -b $part ]] && break
      sleep 0.5
    done
    [[ -n $part && -b $part ]] || die "oddíl na $USB se nevytvořil"
    mkfs.vfat -F32 -n WIN11AUTO "$part" >/dev/null
    mnt=$(mktemp -d)
    mount "$part" "$mnt"
    rsync -rt --inplace --no-perms --info=progress2 "$X"/ "$mnt"/
    sync
    umount "$mnt"; rmdir "$mnt"
  fi
  log "Hotovo: flešku můžeš vytáhnout"
else
  log "Vytvářím ISO $OUT_ISO"
  xorriso -as mkisofs -quiet -iso-level 3 -J -joliet-long -V WIN11_AUTO \
    -b boot/etfsboot.com -no-emul-boot -boot-load-size 8 \
    -eltorito-alt-boot -e efi/microsoft/boot/efisys.bin -no-emul-boot \
    -o "$OUT_ISO" "$X"
  if [[ $OS == Linux && -n ${SUDO_USER:-} ]]; then chown "$SUDO_USER" "$OUT_ISO" || true; fi
  log "Hotovo: $OUT_ISO ($(du -h "$OUT_ISO" | cut -f1))"
  echo "Pozor: obyčejné ISO se přes dd/Etcher nenabootuje, zapisuj ho přes Ventoy nebo Rufus, nebo spusť skript s --usb."
fi
cat <<'EOF'

Pozor: tohle médium po spuštění BEZ PTANÍ smaže disk 0 a nainstaluje Windows.
Na cílovém notebooku stiskni F12, vyber USB a při hlášce "Press any key" stiskni klávesu.
Po prvním restartu flešku vytáhni.
EOF
