# Windows 11 na ThinkPad T14 Gen 3 (Intel), automatická instalace

Z originálního Windows 11 ISO postaví bootovací flešku, která se nainstaluje bez zásahu: smaže
disk 0, Windows 11 Home, lokální účet bez hesla, kompletní Lenovo driver pack (video, touchpad,
Serial IO, wifi, Bluetooth, zvuk, čipset) a po instalaci automatický průchod Windows Update.

**Smaže celý disk cílového počítače. Zálohuj.**

Předpoklad: Windows 11 ISO z <https://www.microsoft.com/software-download/windows11> je ve
Stažených (skript si ho najde sám). Zasuň flešku (min. 16 GB, jediný externí disk).

## Ubuntu (rovnou na T14, po zápisu se restartuje do instalace)

```
wget -qO- https://raw.githubusercontent.com/slezacek/Sand-/w11/i|sudo bash
```

Wifi, ke které je počítač připojený, se převezme sama (`--no-wifi` to vypne).

## macOS (fleška se pak vloží do T14 a spustí přes F12)

```
curl -fsSL https://raw.githubusercontent.com/slezacek/Sand-/w11/i|bash
```

Na Macu wifi nejde převzít; přidej `-s -- --usb auto --wifi SSID HESLO`, pokud ji chceš.

## Další volby

```
wget -qO- https://raw.githubusercontent.com/slezacek/Sand-/w11/i|sudo bash -s -- --help
```

Hlavní skript je `win11-t14/build-win11-t14.sh`, `i` ho jen stáhne a spustí s výchozími volbami.
