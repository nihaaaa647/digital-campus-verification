/// Digital Campus ID credential and QR format v1 (docs/credential-spec.md).
///
/// Shared by the student app (build the QR, read the credential) and the guard scanner (verify it).
library;

export 'src/bytes.dart' show bytesToHex, fromBase64Url, hexToBytes, toBase64Url;
export 'src/cbor.dart' show CborException;
export 'src/format.dart'
    show
        buildScanQr,
        collegeSigningInput,
        ctxCred,
        ctxRevo,
        ctxScan,
        decodeCredential,
        defaultMaxAgeS,
        defaultMaxFutureS,
        deviceSigningInput,
        encodeCredential,
        encodeQr,
        encodeSignedCredential,
        formatVersion,
        parseKeySet,
        parseSignedCredential,
        verifyRevocationList,
        verifyScan;
export 'src/models.dart';
export 'src/p256.dart'
    show compressPublicKey, compressedPublicKeyFromSpki, ecdsaDerToRaw, publicKeyOf, signEcdsa, verifyEcdsa;
