#!/usr/bin/env bash
# Postaví Windows 11 médium pro ThinkPad T14 Gen 3, které se nainstaluje samo:
# smaže disk 0, nainstaluje Windows, nahraje Lenovo drivery a pokusí se o aktivaci
# firmwarovým klíčem. Spouští se na Linuxu (Ubuntu), potřebuje internet.
#
#   sudo ./build-win11-t14.sh                  -> vyrobí win11-t14-auto.iso
#   sudo ./build-win11-t14.sh --usb /dev/sdX   -> zapíše rovnou bootovací flešku
#
# Originální Windows 11 ISO si stáhni z microsoft.com/software-download/windows11
# (do Stažených, skript si ho najde sám, nebo ho zadej přes --win-iso).
set -euo pipefail

ISO_IN=""; OUT_ISO="$PWD/win11-t14-auto.iso"; USB=""; EDITION="Pro"
WIN_USER=""; WIN_PASS="${WIN_PASSWORD:-}"; PC_NAME="T14-G3"
LOCALE="cs-CZ"; KBD="0405:00000405"; TZ_WIN="Central Europe Standard Time"
MTYPE=""; PACK=""; SKIP_DRIVERS=0; FORCE=0
WORK="${WORK_DIR:-/var/tmp/win11-t14-build}"
SPLIT_MB="${SPLIT_MB:-3800}"
CATALOG_URL="${LENOVO_CATALOG:-https://download.lenovo.com/cdrt/td/catalogv2.xml}"

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31mCHYBA:\033[0m %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
Použití: sudo ./build-win11-t14.sh [volby]
  --win-iso SOUBOR    originální Windows 11 ISO (jinak se hledá ve Stažených)
  --out SOUBOR        výstupní ISO (výchozí ./win11-t14-auto.iso)
  --usb /dev/sdX      zapsat rovnou na flešku (smaže ji) místo ISO
  --edition Pro|Home  edice Windows (výchozí Pro)
  --user JMENO        jméno lokálního účtu (jinak se zeptá)
  --pc-name NAZEV     název počítače (výchozí T14-G3)
  --type 21AH         typ stroje (výchozí se zjistí z notebooku)
  --driver-pack CESTA driver pack od Lenovo (.exe nebo rozbalená složka)
  --no-drivers        nevkládat Lenovo drivery
  --force             povolit zápis i na disk, který nevypadá jako USB
Heslo účtu lze zadat i proměnnou WIN_PASSWORD.
EOF
}

while (($#)); do
  case $1 in
    --win-iso) ISO_IN=$2; shift 2 ;;
    --out) OUT_ISO=$2; shift 2 ;;
    --usb) USB=$2; shift 2 ;;
    --edition) EDITION=$2; shift 2 ;;
    --user) WIN_USER=$2; shift 2 ;;
    --pc-name) PC_NAME=$2; shift 2 ;;
    --type) MTYPE=$2; shift 2 ;;
    --driver-pack) PACK=$2; shift 2 ;;
    --no-drivers) SKIP_DRIVERS=1; shift ;;
    --force) FORCE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage; die "neznámá volba: $1" ;;
  esac
done

[[ $EUID -eq 0 ]] || exec sudo -E "$0" "$@"

case ${EDITION,,} in
  pro)  EDITION=Pro;  WIN_KEY="VK7JG-NPHTM-C97JM-9MPGT-3V66T" ;;
  home) EDITION=Home; WIN_KEY="YTMG3-N6DKC-DKB77-7M9GH-8HVX7" ;;
  *) die "edice musí být Pro nebo Home" ;;
esac
IMAGE_NAME="Windows 11 $EDITION"

# --- závislosti -------------------------------------------------------------
need=()
for pair in 7z:p7zip-full wimlib-imagex:wimtools xorriso:xorriso innoextract:innoextract \
            rsync:rsync python3:python3 curl:curl parted:parted mkfs.vfat:dosfstools; do
  command -v "${pair%%:*}" >/dev/null || need+=("${pair##*:}")
done
if ((${#need[@]})); then
  log "Instaluji: ${need[*]}"
  command -v apt-get >/dev/null || die "chybí ${need[*]} a není apt-get"
  apt-get update -qq && apt-get install -y -qq "${need[@]}"
fi

# --- vstupy -------------------------------------------------------------------
if [[ -z $ISO_IN ]]; then
  ISO_IN=$(find /home /root /media /mnt "$PWD" -maxdepth 3 -type f -iname '*.iso' -size +3G \
             \( -iname '*win*11*' -o -iname 'Win11*' \) -printf '%s %p\n' 2>/dev/null \
           | sort -rn | head -1 | cut -d' ' -f2-)
  [[ -n $ISO_IN ]] || die "nenašel jsem Windows 11 ISO. Stáhni ho z microsoft.com/software-download/windows11 a spusť znovu (nebo použij --win-iso)."
fi
[[ -f $ISO_IN ]] || die "ISO neexistuje: $ISO_IN"
log "Zdrojové ISO: $ISO_IN"

if [[ -z $WIN_USER ]]; then
  def=${SUDO_USER:-uzivatel}
  read -rp "Jméno lokálního účtu ve Windows [$def]: " WIN_USER
  WIN_USER=${WIN_USER:-$def}
fi
if [[ -z $WIN_PASS ]]; then
  read -rsp "Heslo účtu $WIN_USER: " WIN_PASS; echo
  read -rsp "Heslo znovu: " p2; echo
  [[ $WIN_PASS == "$p2" ]] || die "hesla se neshodují"
fi
[[ -n $WIN_PASS ]] || die "heslo nesmí být prázdné"

if [[ -n $USB ]]; then
  [[ -b $USB ]] || die "$USB není blokové zařízení"
  tran=$(lsblk -dno TRAN "$USB" 2>/dev/null || true)
  if [[ $tran != usb && $FORCE -ne 1 ]]; then
    die "$USB nevypadá jako USB disk (TRAN='$tran'). Pokud to opravdu chceš, přidej --force."
  fi
  if lsblk -nro MOUNTPOINT "$USB" | grep -qE '^(/|/boot|/boot/efi|/home)$'; then
    die "$USB obsahuje systémové oddíly tohoto počítače, odmítám"
  fi
fi

if [[ -z $MTYPE && $SKIP_DRIVERS -eq 0 && -z $PACK ]]; then
  vendor=$(cat /sys/class/dmi/id/sys_vendor 2>/dev/null || true)
  pname=$(cat /sys/class/dmi/id/product_name 2>/dev/null || true)
  [[ ${vendor,,} == *lenovo* ]] || die "nespouštím na Lenovo (vendor='$vendor'); zadej --type 21AH nebo --driver-pack"
  MTYPE=${pname:0:4}
  log "Model: $(cat /sys/class/dmi/id/product_version 2>/dev/null) (typ $MTYPE)"
fi

mkdir -p "$WORK/cache"
X="$WORK/tree"
rm -rf "$X"; mkdir -p "$X"
trap 'rm -rf "$X" "$WORK/single.wim"' EXIT

avail=$(df --output=avail -B1 "$WORK" | tail -1)
((avail > 28*1024*1024*1024)) || die "v $WORK je málo místa (potřeba ~28 GB, WORK_DIR jde změnit)"

# --- rozbalení Windows ISO ------------------------------------------------------
log "Rozbaluji Windows ISO (pár minut)"
7z x -y -bd -o"$X" "$ISO_IN" >/dev/null || die "rozbalení ISO selhalo"
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
size=$(stat -c %s "$WORK/single.wim")
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
if ((SKIP_DRIVERS == 0)); then
  if [[ -z $PACK ]]; then
    log "Hledám driver pack pro typ $MTYPE v katalogu Lenovo"
    curl -fsSL --retry 3 "$CATALOG_URL" -o "$WORK/cache/catalog.xml" \
      || die "nepodařilo se stáhnout katalog Lenovo ($CATALOG_URL); stáhni pack ručně a použij --driver-pack"
    url=$(python3 - "$WORK/cache/catalog.xml" "$MTYPE" <<'PY'
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
PY
    ) || true
    [[ -n $url ]] || die "v katalogu Lenovo není driver pack pro Windows 11 a typ $MTYPE; stáhni ho ručně z pcsupport.lenovo.com a použij --driver-pack"
    PACK="$WORK/cache/$(basename "$url")"
    log "Stahuji $url"
    curl -fL --retry 5 -C - -o "$PACK" "$url" || die "stažení driver packu selhalo"
  fi

  log "Připravuji drivery"
  DRV="$WORK/cache/drivers"
  rm -rf "$DRV"; mkdir -p "$DRV"
  if [[ -d $PACK ]]; then
    cp -a "$PACK/." "$DRV/"
  else
    innoextract -q -d "$DRV" "$PACK" >/dev/null 2>&1 || 7z x -y -bd -o"$DRV" "$PACK" >/dev/null 2>&1 || true
  fi
  ninf=$(find "$DRV" -type f -iname '*.inf' | wc -l)
  if ((ninf > 0)); then
    log "Nalezeno $ninf souborů .inf"
    cp -a "$DRV" "$OEM/Lenovo"
    # do instalátoru (WinPE) jen úložiště a síť, aby byl disk vidět i v režimu Intel RST
    python3 - "$DRV" "$X/\$WinPEDriver\$" <<'PY'
import os, re, shutil, sys
src, dst = sys.argv[1], sys.argv[2]
dirs = set()
for d, _, files in os.walk(src):
    for f in files:
        if not f.lower().endswith('.inf'):
            continue
        raw = open(os.path.join(d, f), 'rb').read()
        if raw[:2] in (b'\xff\xfe', b'\xfe\xff'):
            text = raw.decode('utf-16', 'ignore')
        else:
            text = raw.decode('utf-8-sig', 'ignore')
        if re.search(r'^\s*Class\s*=\s*(SCSIAdapter|HDC|Net)\b', text, re.I | re.M):
            dirs.add(d)
for n, d in enumerate(sorted(dirs)):
    shutil.copytree(d, os.path.join(dst, '%03d_%s' % (n, os.path.basename(d))), dirs_exist_ok=True)
print('WinPE driver složek:', len(dirs))
PY
  else
    log "Pack se nepodařilo rozbalit na Linuxu, nainstaluje se tichým spuštěním ve Windows"
    cp "$PACK" "$OEM/LenovoPack.exe"
  fi
fi

# --- skripty a odpovědní soubor ------------------------------------------------------
crlf() { sed -i 's/$/\r/' "$1"; }

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
            <Password>
              <Value>@PASS@</Value>
              <PlainText>true</PlainText>
            </Password>
          </LocalAccount>
        </LocalAccounts>
      </UserAccounts>
      <AutoLogon>
        <Username>@USER@</Username>
        <Enabled>true</Enabled>
        <LogonCount>1</LogonCount>
        <Password>
          <Value>@PASS@</Value>
          <PlainText>true</PlainText>
        </Password>
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
KEY="$WIN_KEY" WUSER="$WIN_USER" WPASS="$WIN_PASS" \
python3 - "$WORK/autounattend.tpl" "$X/autounattend.xml" <<'PY'
import os, sys
from xml.sax.saxutils import escape
vals = {'UILANG': os.environ['UILANG'], 'KBD': os.environ['KBD'], 'LOCALE': os.environ['LOCALE'],
        'TZ': os.environ['TZW'], 'PCNAME': os.environ['PCNAME'], 'KEY': os.environ['KEY'],
        'USER': os.environ['WUSER'], 'PASS': os.environ['WPASS']}
text = open(sys.argv[1], encoding='utf-8').read()
for k, v in vals.items():
    text = text.replace('@%s@' % k, escape(v))
open(sys.argv[2], 'w', encoding='utf-8').write(text)
PY
rm -f "$WORK/autounattend.tpl"
unset WIN_PASS p2

# --- výstup -----------------------------------------------------------------------------
if [[ -n $USB ]]; then
  log "Zapisuji na $USB"
  lsblk -o NAME,SIZE,MODEL,TRAN "$USB"
  read -rp "Celý obsah $USB bude SMAZÁN. Pro potvrzení napiš ANO: " ans
  [[ $ans == ANO ]] || die "zrušeno"
  for p in $(lsblk -nrpo NAME "$USB" | tail -n +2); do umount "$p" 2>/dev/null || true; done
  wipefs -a "$USB" >/dev/null
  parted -s "$USB" mklabel gpt mkpart WIN11AUTO fat32 1MiB 100% set 1 msftdata on
  partprobe "$USB" || true
  if command -v udevadm >/dev/null; then udevadm settle || true; fi
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
  log "Hotovo: flešku $USB můžeš vytáhnout"
else
  log "Vytvářím ISO $OUT_ISO"
  xorriso -as mkisofs -quiet -iso-level 3 -J -joliet-long -V WIN11_AUTO \
    -b boot/etfsboot.com -no-emul-boot -boot-load-size 8 \
    -eltorito-alt-boot -e efi/microsoft/boot/efisys.bin -no-emul-boot \
    -o "$OUT_ISO" "$X"
  [[ -n ${SUDO_USER:-} ]] && chown "$SUDO_USER" "$OUT_ISO" || true
  log "Hotovo: $OUT_ISO ($(du -h "$OUT_ISO" | cut -f1))"
fi
cat <<EOF

Pozor: tohle médium po spuštění BEZ PTANÍ smaže disk 0 a nainstaluje Windows.
Na cílovém notebooku stiskni F12, vyber USB a při hlášce "Press any key" stiskni klávesu.
Po prvním restartu flešku vytáhni.
EOF
