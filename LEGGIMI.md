# Xtream per iPhone (versione 3.0)

App per iPhone fatta apposta per il telefono, in verticale e con tema scuro.
Parla direttamente con il server Xtream (non serve il PC acceso).

Novità della versione 3.0:
- Multischermo: fino a 4 canali insieme (quanti dipende dalle connessioni del tuo abbonamento).
  Si apre dalla sezione TV, oppure dal pulsante "Multi" mentre guardi un canale.
  Tocchi un riquadro per sentirne l'audio; in basso: Aggiungi, Cambia, Togli, Schermo intero.
- Nuova grafica: la Home si colora con la locandina in primo piano, le locandine in evidenza
  scorrono al centro, la barra delle sezioni è sospesa in basso, "Cerca" è una sezione a sé.
- In Home un tocco per tornare all'ultimo canale o riprendere film ed episodi.

Dalla versione 2.0: player nativo con i comandi in ordine, Picture in Picture automatico
quando esci dall'app (va attivato in Impostazioni dell'iPhone > Generali > Picture in Picture),
guida dei programmi con "Rivedi", e "Organizza" per le categorie di TV, Film e Serie.

Se aggiorni un repository GitHub che avevi già: carica tutto il contenuto di questa cartella
sopra i file vecchi (quelli con lo stesso nome vengono sostituiti).

## 1. Compila l'app su GitHub (gratis, circa 10 minuti)

1. Crea un account gratuito su https://github.com (se non ce l'hai).
2. In alto a destra premi **+** → **New repository**. Dagli un nome (per esempio `xtream-iphone`),
   scegli **Private** e premi **Create repository**.
3. Nella pagina che si apre premi **uploading an existing file**.
4. Trascina dentro **tutto il contenuto** di questa cartella (anche la cartella `.github`)
   e premi **Commit changes**.
5. Apri la scheda **Actions**: la compilazione parte da sola ("Compila app iPhone").
   Se non parte, scegli "Compila app iPhone" a sinistra e premi **Run workflow**.
6. Quando diventa verde, aprila e in fondo, alla voce **Artifacts**, scarica **XtreamPlayer-ipa**.
   È uno zip: dentro c'è **XtreamPlayer.ipa**.

Se la cartella `.github` non si carica, crea a mano il file: **Add file → Create new file**,
nome `.github/workflows/ios.yml`, e incolla il contenuto del file `ios.yml` di questa cartella.

In alternativa puoi usare Codemagic (https://codemagic.io): collega il repository GitHub
e avvia il workflow "Compila app iPhone" del file `codemagic.yaml`.

## 2. Installa l'app sull'iPhone con Sideloadly (dal PC Windows)

1. Installa sul PC **iTunes** e **iCloud** scaricandoli dal sito Apple (non dal Microsoft Store),
   poi **Sideloadly** da https://sideloadly.io
2. Collega l'iPhone al PC con il cavo e, se richiesto, tocca **Autorizza** sull'iPhone.
3. In Sideloadly trascina **XtreamPlayer.ipa**, scrivi il tuo **ID Apple** e premi **Start**.
4. Sull'iPhone attiva la **Modalità sviluppatore**: Impostazioni → Privacy e sicurezza →
   Modalità sviluppatore (l'iPhone si riavvia).
5. Poi Impostazioni → Generali → VPN e gestione dispositivo → tocca il tuo ID Apple → **Autorizza**.

Con un ID Apple gratuito l'app funziona **7 giorni**: poi va reinstallata con Sideloadly
(i dati e le playlist restano). Sideloadly può rinnovarla da solo se PC e iPhone sono sullo stesso Wi-Fi.
Con l'account sviluppatore Apple (99 € l'anno) dura un anno.

## Video che non partono

Il player di iOS legge la diretta in formato HLS e i film in MP4.
Se un contenuto non parte (per esempio i film in MKV o l'audio Dolby di alcuni canali),
premi **Apri in VLC**: installa prima VLC, gratis dall'App Store.

## Cosa c'è nella cartella

- `Sources/` — il codice dell'app (Swift)
- `Resources/web/` — l'interfaccia (la stessa dell'app per PC)
- `Resources/Assets.xcassets/` — icona e colore di avvio
- `Support/Info.plist` — impostazioni dell'app
- `project.yml` — descrizione del progetto (da cui si crea il progetto Xcode)
- `.github/workflows/ios.yml` e `codemagic.yaml` — le istruzioni per la compilazione nel cloud
