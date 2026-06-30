# Berryton — notes de conception & protocole

Doc déportée hors des sources `.be` pour limiter la taille des fichiers (le compilateur Berry
embarqué de Tasmota charge toute la source en RAM ; le pic de compilation est par-fichier, donc
on garde chaque module léger). Voir aussi la mémoire projet `airton-protocol-reference`.

Crédits : protocole Airton par ouinouin & brice (pingus.org). Snippet CRC :
github.com/peepshow-21/ns-flash (berry/nxpanel.be).

TODO : quiet mode (fan), boost mode (fan).

## Vocabulaire de la régulation (Berryton.be)

La régulation est **par mode AC (heat / cool)**, résolue au runtime depuis `ac_mode` via les helpers `reg_*`.

- `reg_source(ac_mode)` : `"ac"` = l'AC régule sur sa propre sonde (on applique `reg_offset`) ;
  `"mqtt"`/`"http"` = l'ESP régule en hystérésis sur la température de pièce externe.
- `temperature_setpoint` : la consigne **utilisateur**, ce que demande l'utilisateur/HA. **Source unique de
  vérité** : c'est ce qu'on renvoie toujours à HA, jamais offsetté, jamais 17/31.
- `temperature_setpoint_to_ac_unit` : la valeur réellement poussée à l'AC en mode hystérésis ; forcée à 17 ou
  31 °C pour faire tourner l'unité à fond ou la mettre en pause (n'a de sens que quand l'ESP régule).
- `reg_offset(ac_mode)` : en mode `"ac"`, ajouté (heat) / soustrait (cool) à la consigne envoyée à l'AC pour
  que sa sonde haute/encastrée régule quand même correctement la pièce. L'offset n'est appliqué **que** sur la
  trame envoyée à l'AC : il ne fuit jamais vers HA.

Modes ≠ heat/cool (auto/dry/fan_only/off) : pas de régulation ESP → traités comme source `"ac"`, offset 0.

### Invariant HA
HA reçoit **toujours** `temperature_setpoint` (consigne utilisateur). L'offset et les bornes 17/31 de
l'hystérésis ne sortent que vers l'AC, jamais vers HA. La température courante remontée à HA est
sélectionnable (`ha_current_temp_source` : sonde AC vs source de régulation), publiée sur un topic unique.

### Réconciliation IR / changements externes (A3-diff)
Quand l'utilisateur agit sur la télécommande IR (ou tout changement non commandé par nous), la clim l'annonce
dans sa trame **A3** (la trame A4 ne porte que « wifi on/off », inutilisable). On se resynchronise à **chaque
A3** par comparaison de valeur (pas de compteur/timing, donc insensible à une trame perdue) : on n'adopte que
sur un **changement trame-à-trame** vers une valeur qu'on **n'a pas commandée** — ce qui filtre l'écho de notre
propre commande (l'AC rapporte brièvement l'ancienne valeur stable, puis rattrape la valeur envoyée).
- **Consigne** (uniquement en mode `"ac"`) : `last_sent_to_ac` = la valeur byte-13 qu'on a forgée. Si la consigne
  de l'A3 change ET ≠ `last_sent_to_ac` → télécommande → `user_setpoint = ac_sp ∓ offset` (inversion de l'offset),
  publié vers HA + persisté. En mode hystérésis ESP on ne synchronise pas (l'ESP possède la consigne).
- **Mode / fan / swing** : « ce qu'on a envoyé » = la variable d'état courante (`ac_mode`,
  `fan_speed_setpoint`, `oscillation_mode_setpoint`) ; même règle de détection de changement, sans offset.
Implémenté dans `publish_feedback` ; validé sur testberry (écho / retard d'aller-retour / vraie télécommande).

## Trames série (Airton)

Structure commune : `7A 7A | src | dst | len | hdr2(2) | type | 0A 0A | … | CRC16(2)`.
src/dst : `0x21` = ESP, `0xD5` = AC. CRC = MODBUS (poly 0xA001, init 0xFFFF), 2 octets de fin.

| Type | Sens | Long. | Rôle | Géré par Berryton |
|------|------|-------|------|-------------------|
| A1 | ESP→AC | 24 | Commande (mode/fan/setpoint/swing/config word) | `forge_payload` (émis) |
| A3 | AC→ESP | 34 | Feedback complet de l'AC | `publish_feedback` (décodé) |
| A4 | AC→ESP | 13 | Changement d'état télécommande IR. byte 10 : `0x00`=on, `0x01`=off, `0xA5`=inconnu | `decode_remote_control` (lu, lecture seule — base de la sync IR à venir) |
| AB | ESP→AC | 12 | Heartbeat du module Wi-Fi, /60 s. Constante `7A7A21D50C0000AB0A0A`+CRC. Garde l'icône Wi-Fi allumée sur l'afficheur ; aucune réponse attendue | `send_heartbeat` (émis) |
| AC | AC→ESP | 18 | Réponse au heartbeat | ignoré (test/réservé d'après la doc de réf) |

Référence faisant autorité : https://github.com/TheMiNuS/UnleashedAirConditionner (`Protocol/protocol_Airton.md`).

## Contrainte mémoire (ESP32 + Tasmota Berry)

- Le pic de compilation est **par-fichier** (∝ taille source × ~1,5–2) ; le bytecode résultant et le runtime
  de tous les modules s'additionnent dans le heap GC (persistant).
- Sur le banc (testberry) : heap libre ~65 Ko, GC Berry 72 Ko. À ~36 Ko de source un seul fichier, le pic
  frôle l'OOM si le heap est fragmenté → `BrRestart` peut échouer là où un `Restart` complet passe.
- **Au déploiement sur clim.lan** : après un upload qui agrandit un module, faire un `Restart` complet (pas
  juste `BrRestart`).
- Compilation hors-ligne en `.bec` : **non viable** — le bytecode est spécifique à l'architecture (32 bits
  Tasmota ≠ 64 bits du PC) ; un `.bec` compilé sur PC se charge sans erreur mais n'exécute rien. Rester en `.be`.
