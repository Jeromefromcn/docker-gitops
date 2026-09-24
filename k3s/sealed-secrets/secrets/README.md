# Sealed Secrets

`SealedSecret` manifests land here, one file per migrated Secret. Each
is safe to commit — the payload is encrypted with the cluster's
sealed-secrets public key and can only be decrypted by the controller
running in the `sealed-secrets` namespace.

Produced by `kubeseal --controller-name sealed-secrets --controller-namespace sealed-secrets`,
never hand-written.
