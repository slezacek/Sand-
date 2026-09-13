# Přesun na self-hosted prostředí (tvůj server) — návod

**Cíl:** Dostat Claude Code cloud session na infrastrukturu, kde odchozí síť řídí tvůj server, ne Anthropic egress proxy — aby šlo dotáhnout `roboforex.com` / `copyfx.com`.

---

## ⚠️ Kritická podmínka — ověř JAKO PRVNÍ

Self-hosted prostředí jsou (stav ke zjištění z dokumentace, public beta) dostupná **jen na Team a Enterprise plánu** a musí je zapnout **Owner organizace** v admin nastavení. Pokud máš osobní Pro/Max účet (ne Team/Enterprise organizaci), tahle cesta **není k dispozici vůbec** a je potřeba to řešit jinak (např. přechod na Team plán, nebo někoho v týmu, kdo je Owner).

→ Zkontroluj na https://claude.ai/admin-settings/cloud-environments, jestli vidíš sekci **Self-hosted environments** a tlačítko **New**. Pokud ne, buď nemáš Team/Enterprise, nebo to zatím nemáš zapnuté jako Owner.

---

## Co self-hosted prostředí řeší (a co ne)

- **Řeší:** odchozí síť session pak jde přes tvůj vlastní server/síť, ne přes Anthropic cloud egress proxy s organizační allowlistou, která teď blokuje `roboforex.com`/`copyfx.com`/dokonce Wikipedii.
- **Neřeší automaticky:** pokud by tvůj vlastní server měl firewall/proxy, který by RoboForex/CopyFX taky blokoval, problém zůstává — ale to je pak tvoje vlastní síť, kterou ovládáš a můžeš upravit.
- Model inference (samotné Claude API volání) pořád jde na `api.anthropic.com` — jen běh session (git clone, shell příkazy, **web fetch**) se odehrává na tvém stroji/v tvé síti.

---

## Postup (manuální varianta)

### 1) Předpoklady na serveru
- Linux nebo macOS host (Windows nepodporován — spustit v Linux kontejneru).
- Outbound HTTPS na `api.anthropic.com` a `claude.ai` (+ instalační zdroje) a na tvůj git host (GitHub).
- Synchronizované hodiny (NTP) — autentizace selže při rozdílu > 5 minut.
- Nainstalovaný **Claude Code v2.1.224+** a **Git 2.24+**.

Ověření připravenosti hosta:
```bash
claude self-hosted-runner --help
```
Pokud to vypíše obecnou nápovědu `claude --help` místo runner nápovědy, je potřeba `claude update` / reinstalace z `latest` kanálu.

### 2) Nejjednodušší cesta — řízený setup
Na stroji, kde jsi přihlášený (`claude auth login`) účtem s rolí **Owner**:
```bash
claude self-hosted-runner setup
```
Tohle tě provede interaktivně: založení prostředí v admin UI, spuštění lokálního runneru se secret souborem, ověření registrace, a vygeneruje cheat sheet do `./runner-setup/CHEAT-SHEET.md`.

### 3) Manuální varianta (krok za krokem)

**a) Založ prostředí**
- https://claude.ai/admin-settings/cloud-environments → **Self-hosted environments** → **New** → pojmenuj → **Create**.
- Na druhém kroku wizardu: **Copy environment key** (zobrazí se jen jednou! ulož si ho). Environment má i `ccpool_...` ID — to si taky ulož, budu ho potřebovat pro spuštění návazné session.

**b) Spusť runner na serveru**
```bash
mkdir -p /etc/claude
(umask 077 && cat > /etc/claude/environment-secret)
# vlož zkopírovaný secret, Enter, pak Ctrl-D

claude self-hosted-runner --environment-secret-file '/etc/claude/environment-secret' --base-dir '<zapisovatelný-adresář>'
```
(`<zapisovatelný-adresář>` = libovolná cesta, kam může runner zapisovat; bez `--base-dir` použije `/workspace`.)

**c) Ověř, že runner naskočil**
Zpět na https://claude.ai/admin-settings/cloud-environments — status prostředí by se měl změnit z **No runners deployed** na **Healthy** během pár vteřin.

**d) Spusť/přesměruj session do tohoto prostředí**
- Buď na claude.ai/code při zakládání nové session vyber v environment pickeru svoje nové (self-hosted) prostředí,
- nebo mi jen pošli **`ccpool_...` ID** — já pak přes svůj nástroj (`create_session`) rovnou založím novou session v tomhle environmentu, napojenou na repozitář `slezacek/sand-` a s kompletním kontextem naší analýzy NovaTerra/RoboForex, ať nemusíš nic ručně opisovat.

### 4) Test, že to řeší egress problém
V nové session (na tvém runneru) zkus jednoduše:
```bash
curl -sS -o /dev/null -w "%{http_code}\n" https://roboforex.com/
```
Pokud vrátí `200`/`30x` místo `403`/timeoutu, egress blokace je pryč a můžu pokračovat v dotažení dat z ratingu.

---

## Co udělám hned, jak mi dáš `ccpool_...` ID

1. Založím novou session v tomto environmentu (`create_session`, `environment_id = ccpool_...`), napojenou na `slezacek/sand-`, branch `claude/novaterra-roboforex-comparison-sbe1tm`.
2. V ní ověřím, že `roboforex.com`/`copyfx.com` je skutečně dostupný.
3. Dotáhnu žebříček TOP strategií + strategii NovaTerra (`trader_account=47145356`), doplním tabulky v `novaterra-roboforex-porovnani.md`, dopočítám čistý výnos po poplatcích a poměr výnos/drawdown, commitnu a pushnu.

---

## Zdroje (dokumentace Claude Code)
- https://code.claude.com/docs/en/self-hosted-environments
- https://code.claude.com/docs/en/self-hosted-environments-quickstart
- https://code.claude.com/docs/en/self-hosted-environments-deploy
