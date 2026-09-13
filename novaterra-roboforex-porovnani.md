# NovaTerra vs. TOP strategie RoboForex Copy Trading — porovnání ziskovosti a rizika

**Stav:** Nedokončeno — chybí reálná data ze žebříčku RoboForex (viz sekce „Co se nepodařilo a proč" níže). Dokument obsahuje strukturu, metodiku a vše, co se podařilo ověřit z veřejně dostupných zdrojů; čísla pro konkrétní strategie je potřeba doplnit.

---

## 1. Co se nepodařilo a proč

Zadání počítalo s tím, že stránka `roboforex.com/copy-trading/rating/` (resp. `copyfx.com/ratings/...`) je SPA a data se dotahují přes JS/API volání — což se potvrdilo. Problém je ale o úroveň níž:

- **Veškerý odchozí HTTP fetch je v tomto prostředí zablokovaný na síťové proxy**, a to plošně — netýká se to jen domény `roboforex.com`/`copyfx.com`. Otestoval jsem to i na zcela neutrální doméně (`en.wikipedia.org`) a dostal jsem stejnou chybu `EGRESS_BLOCKED`. Jde tedy o omezení tohoto konkrétního session/prostředí, ne o blokaci ze strany RoboForexu.
- Nástroj pro vyhledávání (`WebSearch`) funguje, ale vrací jen agregované textové výtahy ze search indexu — ne skutečný obsah stránky ani JSON odpověď z API. Přes opakované dotazy se mi nepodařilo najít žádnou veřejně indexovanou zmínku o strategii "NovaTerra" ani o account ID `47145356` — což dává smysl, protože živá data ratingu se do vyhledávačů neindexují.
- Nemám tedy možnost:
  - zachytit konkrétní API endpoint z Network tabu (to vyžaduje skutečné načtení stránky v prohlížeči/headless browseru, který v tomto sessionu nemám k dispozici a zároveň by narazil na stejnou síťovou blokaci),
  - stáhnout tabulku TOP strategií,
  - dohledat strategii NovaTerra / účet 47145356 v žebříčku.

**Nejde o problém s přihlášením ani o porušení robots.txt/ToS** — je to tvrdá síťová restrikce tohoto prostředí. Odpovídá to tvému pokynu „pokud narazíš na blokaci, zastav se a napiš mi to" — proto nepokračuji obcházením (např. přes proxy služby třetích stran), a raději ti popisuju přesně, kde to vázne.

### Jak to dodat rychle beze mě
Nejrychlejší cesta k reálným číslům:
1. Přihlas se na `my.roboforex.com` → Copy Trading → Rating.
2. Otevři DevTools (F12) → záložka Network → filtr XHR/Fetch → načti/refreshni stránku ratingu.
3. Najdi request, který vrací JSON s polem typu `strategies`/`traders`/`rating` (obvykle na doméně `my.roboforex.com/api/...` nebo `copyfx.com/api/...`).
4. Buď mi vlož přímo ten JSON (response body), nebo mi pošli URL + potřebné auth hlavičky/cookies pro daný request — z toho už tabulku sestavím a spočítám metriky.
5. Pro NovaTerra konkrétně: ve filtru žebříčku vyhledej `trader_account=47145356` nebo název "NovaTerra" a exportuj/zkopíruj jeho řádek (Profit 1M/3M/12M, Max DD, fee, počet investorů, doba běhu).

Jakmile mi data dodáš (JSON, CSV export z platformy, nebo i screenshoty tabulky), doplním čísla do tabulek níže a dopočítám čistý výnos po poplatcích a poměr výnos/drawdown.

---

## 2. Co se ověřit podařilo (obecný kontext, ne konkrétní čísla)

Z veřejně dostupných stránek/recenzí (help centrum RoboForexu, tiskové zprávy, srovnávací weby) se potvrdilo:

- **Fee model:** Poskytovatel strategie si může nastavit tzv. Performance Fee v rozsahu **5–50 %** ze zisku investora. Poplatek se strhává až na konci investičního období nebo při zrušení odběru (ne hned po každém ziskovém obchodu) — tzn. u srovnání je nutné počítat s reálným, ne nominálním čistým výnosem.
- Alternativa k performance fee je fixní subskripční poplatek (podle typu strategie).
- **Klasifikace rizika podle max. drawdownu** (obecně používaná RoboForexem/CopyFX v jejich materiálech):
  - do **30 % DD** → konzervativní
  - **30–50 % DD** → střední riziko
  - **nad 50 % DD** → vysoké riziko
- Rating se sestavuje kombinací performance, drawdownu a délky historie (longevity) — tedy nová strategie s krátkou historií z principu nemůže mít vysoké skóre, i kdyby měla dobrý krátkodobý výnos.
- Koncem roku 2025 RoboForex sjednotil CopyFX pod nový branding "Copy Trading Service" a podle jedné zprávy zpřístupnil rating bez nutnosti loginu — to by teoreticky mělo zjednodušit budoucí získání dat, ale sám fetch stránky se mi kvůli síťové blokaci ověřit nepodařilo.

Zdroje (textové výtahy z vyhledávání, ne plný obsah stránek):
- RoboForex Copy Trading Service — Complete Guide (tradersunion.com)
- What information is displayed in the Rating? (copyfx.com FAQ)
- How is the Copy Trading Service Rating formed? (help.roboforex.com)
- RoboForex Introduces a Performance Fee Scheme (myfxbook.com press release)
- RoboForex Upgrades CopyFX Into A Unified Copy Trading Hub (financialcommission.org, 11/2025)

---

## 3. Šablona porovnání — k doplnění reálnými daty

### 3.1 NovaTerra

| Metrika | Hodnota |
|---|---|
| Trader account ID | 47145356 |
| Profit/ROI — 1M | *(TBD)* |
| Profit/ROI — 3M | *(TBD)* |
| Profit/ROI — 12M | *(TBD)* |
| Max Drawdown % | *(TBD)* |
| Performance/Volume Fee % | *(TBD)* |
| Počet aktivních investorů | *(TBD)* |
| Doba fungování (dny/měsíce) | *(TBD)* |
| Risk score (pokud dostupný) | *(TBD)* |
| **Čistý roční výnos po poplatcích** (dopočet) | *(TBD)* |
| **Poměr výnos/drawdown** (dopočet) | *(TBD)* |

### 3.2 TOP 5–10 strategií dle žebříčku RoboForex

| Pořadí | Název/ID | ROI 1M | ROI 3M | ROI 12M | Max DD % | Fee % | Investoři | Doba běhu | Čistý roční výnos po fee | Výnos/DD |
|---|---|---|---|---|---|---|---|---|---|---|
| 1 | *(TBD)* | | | | | | | | | |
| 2 | *(TBD)* | | | | | | | | | |
| 3 | *(TBD)* | | | | | | | | | |
| 4 | *(TBD)* | | | | | | | | | |
| 5 | *(TBD)* | | | | | | | | | |
| 6 | *(TBD)* | | | | | | | | | |
| 7 | *(TBD)* | | | | | | | | | |
| 8 | *(TBD)* | | | | | | | | | |
| 9 | *(TBD)* | | | | | | | | | |
| 10 | *(TBD)* | | | | | | | | | |

### 3.3 Metodika dopočtu (jakmile budou vstupy)

- **Čistý roční výnos po poplatcích** = ROI 12M × (1 − fee %) — případně přepočet z kratších období, pokud strategie neběží 12 měsíců (anualizace s poznámkou o krátké historii jako rizikovém faktoru).
- **Poměr výnos/drawdown** = Čistý roční výnos po poplatcích / Max Drawdown % — čím vyšší, tím lepší poměr rizika a výnosu (obdoba zjednodušeného Calmar ratio).
- Strategie s dobou běhu < 6 měsíců budou v porovnání označené jako "nedostatečná historie" bez ohledu na aktuální čísla — krátká historie u affiliate-náborových strategií (jako NovaTerra) je sama o sobě rizikový signál, který do závěru promítneme odděleně od čistě numerického srovnání.

---

## 4. Poznámka k affiliate/náborovému modelu NovaTerra

Nezávisle na chybějících tvrdých datech: pokud byla NovaTerra nabídnutá s partner/affiliate odkazem (`partner_token=or01wvs`) a náborovou strukturou, je to samo o sobě signál k opatrnosti — motivace odesílatele není nutně "tahle strategie je objektivně nejlepší", ale "získám provizi za přivedení investora". To by mělo být v konečném závěru zohledněno jako kvalitativní rizikový faktor navíc k číslům z tabulky výše, jakmile budou k dispozici.
