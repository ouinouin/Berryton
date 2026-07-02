# Trames série Airton — observées sur clim.lan

Structure commune : `7A 7A | src | dst | len | h1 h2 | type | 0A 0A | … données … | CRC16(2)`.
Adresses : `0x21` = ESP (module wifi), `0xD5` = unité AC, `0x21`/`0xD1` selon la trame.
CRC = MODBUS (poly `0xA001`, init `0xFFFF`), 2 octets de fin (hi, lo). `len` (byte 4) = longueur totale.

Table vivante — à compléter au fil des captures. Voir aussi `NOTES.md` et la mémoire `remote-function-mapping`.

## ESP → clim (émission)

| Type | src→dst | Len | Rôle | Champs clés | Exemple | Statut code |
|------|---------|-----|------|-------------|---------|-------------|
| `A1` | 21→D5 | 24 | Commande (mode/fan/consigne/swing/config/beep) | **b10-11 timer (min, little-endian — set/preserve, IMPLÉMENTÉ)** · b12 mode+fan+power · b13 consigne−16 · b14 swing · b15 config word · **b16 beep (CONFIRMÉ : 0x00=bip, 0x01=silencieux — PAS la MAC)** · b17-21 restent à 0 chez nous (l'AC accepte : « MAC » non requise) | `7A7A21D518…+CRC` | `forge_payload` |
| `AB` | 21→D5 | 12 | Heartbeat wifi (/60 s, garde l'icône wifi allumée) | trame **constante**, aucune donnée | `7A7A21D50C0000AB0A0AFCF9` | `send_heartbeat` |

**Config word A1 (byte 15)** : bit7 display · bit6 ionizer · bit4 aux heater · bits3-2 display mode · bit1 sleep · bit0 eco.

## clim → ESP (réception)

| Type | src→dst | Len | Rôle | Champs clés | Exemple | Statut code |
|------|---------|-----|------|-------------|---------|-------------|
| `A3` | D5→21 | 34 | Feedback complet de l'AC | b10-11 temp sonde · b13 mode(0-2)+on/off(3)+fan(4-6) · b14 consigne (nibble bas +16) · b15 swing · **b16 config word** · **b19-20 timer restant (min, little-endian, CONFIRMÉ)** · b21 flag=`01` · b25-31 = série ASCII (ex. `4442313133373 0`="DB11370") · b23-24 heures | `7A7AD521220000A30A0A1700005909008800000000016477FC44423131333730E8D8` | `publish_feedback` + réconciliation A3-diff |
| `A4` | **D1**→21 | 13 | État wifi on/off (bouton télécommande) — événementiel + périodique ~10 s | b10 : `00`=on, `01`=off, `A5`=inconnu | ON `7A7AD1210D0000A40A0A002525` · OFF `7A7AD1210D0000A40A0A01E5E4` | `decode_remote_control` |
| `A6` | D5→21 | 28 | Inconnu (payload tout à zéro), périodique | — | `7A7AD5211C0000A60A0A0000000000000000000000000000000000520B` | loggé (unhandled) |
| `AC` | D5→21 | 18 | Réponse au heartbeat `AB`, données non décodées | b10-16 : `21 50 00 77 FC 00 83` (varie) | `7A7AD521120000AC0A0A21500077FC0083C6` | loggé (unhandled) |

**Config word A3 (byte 16)** — décodé par observation télécommande :
| bit | masque | fonction | statut |
|-----|--------|----------|--------|
| 6 | `0x40` | **ionizer / health / clean** | ✅ confirmé (ON `0xC8` / OFF `0x88`) |
| 7 | `0x80` | display | ✅ confirmé (A3 byte16 `0x98` = display on, suivi par le panneau) |
| 4 | `0x10` | aux heater (présumé) | à confirmer |
| 1 | `0x02` | sleep (présumé) | à confirmer |
| 0 | `0x01` | eco (présumé) | à confirmer |
