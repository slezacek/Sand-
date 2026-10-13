# Windows 11 na ThinkPad T14 Gen 3 (Intel), automatická instalace

`win11-t14/build-win11-t14.sh` z originálního Windows 11 ISO postaví bootovací flešku, která se
nainstaluje bez zásahu: smaže disk 0, Windows 11 Home, lokální účet bez hesla, kompletní Lenovo
driver pack (video, touchpad, Serial IO, wifi, Bluetooth, zvuk, čipset) a po instalaci
automatický průchod Windows Update.

**Smaže celý disk cílového počítače. Zálohuj.**

Předpoklad: Windows 11 ISO z <https://www.microsoft.com/software-download/windows11> je ve
Stažených (skript si ho najde sám).

## Ubuntu (rovnou na T14, po zápisu se restartuje do instalace)

```
wget -qO /tmp/w11.sh https://raw.githubusercontent.com/slezacek/Sand-/claude/win11-t14-installer-sbe1tm/win11-t14/build-win11-t14.sh && sudo bash /tmp/w11.sh --usb auto --reboot --wifi SSID HESLO
```

## macOS (fleška se pak vloží do T14 a spustí přes F12)

```
curl -fsSL https://raw.githubusercontent.com/slezacek/Sand-/claude/win11-t14-installer-sbe1tm/win11-t14/build-win11-t14.sh -o /tmp/w11.sh && bash /tmp/w11.sh --usb auto --wifi SSID HESLO
```

`--wifi SSID HESLO` je volitelné (WPA2), aby po instalaci šel Windows Update bez kabelu.
Heslo patří jen do příkazu, ne do repa. Všechny volby: `bash /tmp/w11.sh --help`.
