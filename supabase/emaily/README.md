# E-mailové šablony Supabase (Authentication → Emails → Templates)

Odkazy vedou na `{{ .SiteURL }}/?token_hash=…&type=…` a ověření udělá až web (index.html, `fromLink()`).
Site URL v Supabase musí být `https://rungame.cz`.

| Šablona v Supabase | Subject | Soubor |
|---|---|---|
| Confirm signup | Potvrď svůj e-mail – RunGame | potvrzeni-registrace.html |
| Reset password | Nové heslo – RunGame | obnova-hesla.html |
| Change email address | Potvrď nový e-mail – RunGame | zmena-emailu.html |
