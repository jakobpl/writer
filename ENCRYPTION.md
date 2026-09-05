# mac_pastebin security model

## How the vault is encrypted

1. A new vault receives a random 16-byte salt from `SecRandomCopyBytes`.
2. PBKDF2-HMAC-SHA256 derives a 32-byte key from the UTF-8 password, salt, and stored iteration count. New vaults use 600,000 iterations. Existing vaults continue using the count recorded when they were created.
3. The complete notes payload, including note titles, timestamps, rich-text formatting, and optimized inline-image bytes, is encoded as a binary property list and sealed with AES-256-GCM through CryptoKit. CryptoKit generates a fresh nonce for every save. Version 1 JSON payloads remain readable and are migrated on save.
4. The vault file stores the salt, KDF settings, nonce, ciphertext, and authentication tag. These values do not need to be secret. The password and derived key are not stored.
5. Unlocking derives the same key and asks AES-GCM to authenticate and decrypt the payload. A wrong password, changed ciphertext, or changed authentication tag fails authentication.

The derived key exists only while the vault is unlocked and is discarded when the app locks. The vault directory and current vault file are restricted to the current macOS user (`0700` and `0600`).

## What this protects

The design protects vault contents copied from disk or backups, provided the password is strong. AES-GCM also detects modifications to the encrypted payload.

It does not protect plaintext while the vault is unlocked. A process with access to the user's session may be able to read memory, observe keystrokes, capture the screen, or inspect copied text. Swift strings and UI controls can make internal copies, so the app cannot guarantee complete password or plaintext zeroization.

The outer vault header is not encrypted. It reveals the format version, payload encoding, creation time, algorithms, KDF work factor, salt, nonce, ciphertext length, and authentication tag. Note content, titles, note timestamps, formatting, attachment names, image bytes, and display sizes are inside the encrypted payload.

## Passwords and recovery

- New vaults require a password of at least 12 characters and matching confirmation. mac_pastebin rejects a small set of known-trivial values. Existing vaults remain unlockable with their original password so the policy does not strand older data.
- Prefer a unique, randomly generated password or a long passphrase stored in a reputable password manager.
- Losing the password means losing access. mac_pastebin has no recovery key, escrow service, reset flow, or back door.
- Changing a password requires decrypting the vault with the old password and re-encrypting it with a new salt and key. mac_pastebin does not currently expose that operation.
- The salt is public and prevents attackers from reusing one precomputed password table across vaults. It does not compensate for a weak password.
- The PBKDF2 iteration count slows offline guessing but cannot stop it. Work factors should be reviewed over time and increased for newly created or re-keyed vaults as hardware improves.

## Operational considerations

- Keep encrypted backups of `vault.mac_pastebin` and any archived vaults. Test that backups can be restored. Backups remain tied to the password used when each vault was created.
- Copying a note places plaintext on the system clipboard. By default mac_pastebin preserves that value when locking so it remains available for pasting. An internal `clearClipboardOnLock` policy can opt into clearing mac_pastebin's unchanged clipboard value; clipboard managers may retain independent history regardless.
- mac_pastebin saves pending changes before locking and quitting. If a disk write fails during locking, it retains an encrypted recovery snapshot in process memory, discards the key, and restores the edits after a successful password unlock. Quitting and vault replacement are blocked until the recovered changes are saved. This snapshot does not survive a crash, force quit, or power loss, so backups remain important. If the app cannot encode and encrypt a recoverable snapshot, it reports the error and keeps the editor open rather than discarding changes.
- The first save of a version 1 vault creates an encrypted `vault.mac_pastebin.migration.*` rollback archive before atomically replacing the current file with version 2.
- New inline images are downsampled and compressed in memory before entering the vault. Images are decrypted in memory while the vault is unlocked. mac_pastebin does not create its own plaintext attachment or thumbnail cache.
- Archived vaults are still encrypted, but they remain sensitive: weak or reused passwords can be attacked offline indefinitely.
- Do not reuse an AES-GCM nonce with the same key. mac_pastebin delegates nonce generation to CryptoKit and creates a new sealed box on every save.
- Any future vault-format change should use a new format version, preserve authenticated decryption, strictly bound attacker-controlled KDF parameters, and include a tested migration and rollback path.

## Resource limits

mac_pastebin applies one resource policy before reading, decoding, decrypting, parsing, importing, or saving vault content. The current limits are:

- 80 MiB encoded vault file and 48 MiB ciphertext/plaintext
- 500 notes, 2 MiB of body text per note, and 8 MiB of body text across the vault
- 16 MiB of stored rich text per note and 32 MiB across the vault
- 64 images per note and 256 across the vault, with 8 MiB per stored legacy image and 24 MiB of image bytes across the vault
- new imports may be up to 40 MiB before processing and are stored at no more than 1,200 pixels on the longest edge and 750 KiB
- still images only, at most 8,192 pixels on either axis, 40 megapixels per image, 80 megapixels per note, 160 megapixels per vault, and a 100:1 maximum aspect ratio

New saves store lightweight RTF attachment markers and keep each optimized image only once. Legacy RTFD packages remain readable; they are inspected before AppKit parsing, and their embedded attachment bytes must match the separately authenticated, ImageIO-preflighted image sources. These limits intentionally trade unusually large documents for bounded unlock, rendering, and recovery behavior.

## Current limitations

- Password derivation uses PBKDF2 because it is available through the platform APIs and is part of the existing format. A memory-hard KDF such as Argon2id would provide better resistance to GPU/ASIC guessing, but adopting it requires a carefully versioned format and a vetted implementation.
- Vault header fields are validated but are not supplied to AES-GCM as additional authenticated data. Content tampering is authenticated; a future format should also cryptographically bind the security-relevant header to the ciphertext.
- There is no optional Keychain/Secure Enclave convenience unlock. Adding one should wrap or store a random vault key rather than store the user's password, and must define device migration and recovery behavior first.
