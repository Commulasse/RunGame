# RunGame

Virtuální běžecké závody – web rungame.cz.

## Dva režimy
- **Ukázka:** `config.js` je prázdný → data jen v prohlížeči, testovací účty.
- **Ostrý provoz:** v `config.js` vyplněná adresa a klíč Supabase → účty, registrace a běhy v databázi.

## Soubory
- `index.html` – celý web (úvod, registrace, účet běžce, administrace)
- `config.js` – Supabase URL + veřejný klíč, číslo účtu pro QR platbu
- `podminky.html`, `pravidla.html`, `gdpr.html` – obchodní podmínky, pravidla a soutěž, osobní údaje
- `supabase/schema.sql` – databáze (vložit do Supabase → SQL Editor → Run)
- `supabase/ukazkove-zavody.sql` – ukázkové závody pro start (nepovinné)
- `_headers` – bezpečnostní hlavičky (Cloudflare Pages / Netlify)
- `.github/workflows/zaloha-databaze.yml` – noční šifrovaná záloha databáze
- `vendor/` – supabase-js 2.119.0, qrcode-generator 1.4.4
- `ocr/`, `fit/` – čtení screenshotů a souborů z hodinek v prohlížeči

## Nasazení
Statický web bez buildu: Cloudflare Pages (výstupní složka `/`) nebo Netlify (`netlify.toml`).
