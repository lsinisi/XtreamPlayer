# Xtream per iPhone (versione 3.5)

App per iPhone fatta apposta per il telefono, in verticale, con tema scuro e tema chiaro.

Novità delle versioni 3.4 e 3.5:
- Tema chiaro e tema scuro: in Impostazioni (o toccando l'iniziale in alto a destra), alla voce
  "Aspetto", scegli Automatico (segue l'iPhone), Chiaro o Scuro. Il colore dell'app si sceglie
  come prima, e vale per tutti e due i temi. I player restano sempre scuri, per vedere meglio i video.
- Grafica rifinita: barre in vetro smerigliato, pulsanti con una luce morbida del colore dell'app,
  piccoli rimbalzi al tocco su locandine e pulsanti, filtri e icone colorati, schermata di accesso
  con un alone colorato, avvisi e finestre più leggibili.
- Player universale aggiornato a VLCKit 4: ora anche lui ha il Picture in Picture (miniplayer).
  Parte da solo quando esci dall'app mentre guardi qualcosa, oppure con il pulsante "Mini".
  Con lo schermo bloccato l'audio continua e funzionano play, pausa, avanti e indietro.
  VLCKit 4 è ancora una versione di prova ("alpha") di VideoLAN: se qualcosa non va, segnalalo.
- Riproduzione più stabile: se l'immagine si blocca mentre l'audio va avanti (nell'app o nel
  miniplayer) il player se ne accorge e si ripara da solo in pochi secondi, senza tornare
  all'inizio; lo stesso se il video resta fermo a caricare a metà.
- Miniplayer dopo il blocco dello schermo: allo sblocco l'immagine torna da sola.
- Miniplayer del player dell'iPhone: l'immagine non si blocca più mentre l'audio va avanti
  (il riquadro del video ora resta agganciato allo schermo anche quando la schermata del player si chiude).
- Con lo schermo bloccato mentre guardi nell'app (senza miniplayer) l'audio continua.
- Se un film si interrompe e riparte da solo, riprende dal punto in cui era (prima tornava all'inizio).
- Chiudendo il miniplayer del player universale con la X il video si mette in pausa (prima l'audio continuava).
- Zapping veloce nelle dirette: nel player dai un colpo veloce verso l'alto per il canale
  successivo, verso il basso per quello precedente; tieni il dito premuto sul video per tornare
  al canale che guardavi prima (anche se è in un'altra categoria). Trascinando piano il dito
  su e giù continui a regolare luminosità (a sinistra) e volume (a destra).
- Anteprima mentre fai zapping: cambiando canale compare una scheda con numero, nome, logo e
  programma in onda; il canale parte dopo un attimo, così puoi dare altri colpi per andare oltre.
  Tocca la scheda per andare subito.
- Ripresa all'avvio: aprendo l'app, se hai lasciato a metà un film o un episodio, ti chiede se
  riprenderlo (si disattiva in Impostazioni, Riproduzione, "Proponi di riprendere").
- Blocco dello schermo nel player: pulsante "Blocca" nella fila dei comandi. Il video continua ma
  i tocchi non fanno niente; tieni premuto il lucchetto in basso per sbloccare.
Parla direttamente con il server Xtream (non serve il PC acceso).

Novità della versione 3.3:
- Player universale dentro l'app (basato su VLC): legge MKV, AVI, audio Dolby AC3 e DTS, HEVC,
  sottotitoli interni e quasi tutti gli altri formati. Parte da solo per i film e gli episodi che
  il player dell'iPhone non legge, e quando un video non si apre ci passa in automatico dallo
  stesso punto. Nella scheda del film c'è il pulsante "Player universale"; in Impostazioni >
  Riproduzione puoi scegliere di usarlo sempre. Con lui non ci sono Picture in Picture e AirPlay.
- Ora si possono scaricare anche i film MKV, AVI e simili.
- La compilazione su GitHub scarica la libreria VLC (file Podfile): ci mette qualche minuto in più
  e l'app pesa circa 50-70 MB in più.

Novità della versione 3.2:
- Anteprima: tieni premuto un canale e parte in un riquadro, senza aprire il player.
- Canale di riserva (si attiva in Impostazioni, Riproduzione): se un canale non parte, l'app prova
  da sola la versione alternativa con lo stesso nome (per esempio HD al posto di FHD).
- Guida TV a griglia: canali in colonna e ore in riga, nella sezione TV, scheda "Guida TV".
- Cerca nei programmi: in Cerca scegli "Programmi TV" e scrivi un titolo; guarda i preferiti e
  i primi 150 canali, per quello che va in onda adesso e nelle prossime ore.
- Numero del canale: pulsante "Numero" nel player delle dirette.
- Episodi: pulsante "Salta 90 s" per la sigla, e l'avviso del prossimo episodio compare un minuto
  prima della fine.
- Scheda di film e serie: pulsante "Trailer" (YouTube), collegamento a TMDB quando il fornitore
  lo indica, e la riga "Simili a questo".
- Filtri nelle categorie di film e serie: anno, voto, genere, solo non ancora visti.
- In Home la riga "Novità dall'ultima visita" con film e serie arrivati da quando hai aperto
  l'app l'ultima volta.

Dalla versione 3.1: download di film ed episodi (solo MP4, M4V, MOV) da vedere senza connessione
in "Scaricati"; "Esporta i miei dati" e "Importa da un file" in Impostazioni per avere gli stessi
preferiti e punti di ripresa su iPhone e PC; gesti nel player (doppio tocco per 10 secondi,
dito su e giù per luminosità e volume) e pulsante "Velocità".

Dalla versione 3.0: multischermo fino a 4 canali insieme (dalla sezione TV o dal pulsante "Multi"
mentre guardi un canale) e nuova grafica con la Home che si colora con la locandina in primo piano.

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
