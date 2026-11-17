package app.dcid.student_app

import android.os.Build
import android.os.Handler
import android.os.Looper
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyInfo
import android.security.keystore.KeyProperties
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.security.KeyFactory
import java.security.KeyPairGenerator
import java.security.KeyStore
import java.security.PrivateKey
import java.security.ProviderException
import java.security.Signature
import java.security.spec.ECGenParameterSpec
import java.util.concurrent.Executors

/**
 * The phone's device key (docs/credential-spec.md section 6, PRD S5): one P-256 key pair inside the
 * Android Keystore. The private key never leaves it. It does not require user authentication, because
 * the QR is re-signed every 30 seconds; the app lock gates the screen instead.
 *
 * Calls (the Dart side is lib/src/keystore_signer.dart):
 *   key {create: bool}  -> null if there is no key and create is false, else
 *                          {publicKey: X.509 SubjectPublicKeyInfo bytes, security: "strongbox"|"tee"|"software"|"unknown"}
 *   sign {message: bytes} -> DER-encoded ECDSA signature over SHA-256(message); never creates a key
 *   deleteKey           -> null
 */
class KeystoreChannel private constructor() {
    private val keyStore: KeyStore = KeyStore.getInstance(PROVIDER).apply { load(null) }

    // Keystore calls can take tens of milliseconds, and StrongBox much longer: keep them off the UI thread.
    private val worker = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())

    private fun handle(call: MethodCall, result: MethodChannel.Result) {
        worker.execute {
            try {
                val value: Any? = when (call.method) {
                    "key" -> key(create = call.argument<Boolean>("create") == true)
                    "sign" -> sign(call.argument<ByteArray>("message") ?: throw IllegalArgumentException("message required"))
                    "deleteKey" -> {
                        keyStore.deleteEntry(ALIAS)
                        null
                    }
                    else -> {
                        main.post { result.notImplemented() }
                        return@execute
                    }
                }
                main.post { result.success(value) }
            } catch (e: NoKeyException) {
                main.post { result.error("no_key", e.message, null) }
            } catch (e: Exception) {
                main.post { result.error("keystore_error", e.message ?: e.javaClass.simpleName, e.javaClass.name) }
            }
        }
    }

    private fun key(create: Boolean): Map<String, Any>? {
        if (!keyStore.containsAlias(ALIAS)) {
            if (!create) return null
            generate()
        }
        val privateKey = keyStore.getKey(ALIAS, null) as PrivateKey
        val publicKey = keyStore.getCertificate(ALIAS).publicKey
        return mapOf("publicKey" to publicKey.encoded, "security" to securityLevel(privateKey))
    }

    private fun generate() {
        // Prefer StrongBox (a separate secure chip) where the phone has one, otherwise the TEE.
        try {
            generate(strongBox = Build.VERSION.SDK_INT >= Build.VERSION_CODES.P)
        } catch (e: ProviderException) {
            // StrongBoxUnavailableException is a ProviderException. Try again without StrongBox.
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.P) throw e
            generate(strongBox = false)
        }
    }

    private fun generate(strongBox: Boolean) {
        val spec = KeyGenParameterSpec.Builder(ALIAS, KeyProperties.PURPOSE_SIGN)
            .setAlgorithmParameterSpec(ECGenParameterSpec("secp256r1"))
            .setDigests(KeyProperties.DIGEST_SHA256)
            .setUserAuthenticationRequired(false)
            .apply { if (strongBox && Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) setIsStrongBoxBacked(true) }
            .build()
        KeyPairGenerator.getInstance(KeyProperties.KEY_ALGORITHM_EC, PROVIDER).apply { initialize(spec) }.generateKeyPair()
    }

    @Suppress("DEPRECATION")
    private fun securityLevel(privateKey: PrivateKey): String {
        val info = KeyFactory.getInstance(privateKey.algorithm, PROVIDER).getKeySpec(privateKey, KeyInfo::class.java)
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            when (info.securityLevel) {
                KeyProperties.SECURITY_LEVEL_STRONGBOX -> "strongbox"
                KeyProperties.SECURITY_LEVEL_TRUSTED_ENVIRONMENT -> "tee"
                KeyProperties.SECURITY_LEVEL_SOFTWARE -> "software"
                else -> "unknown"
            }
        } else {
            if (info.isInsideSecureHardware) "tee" else "software"
        }
    }

    private fun sign(message: ByteArray): ByteArray {
        // A missing key must be an error, not a silently generated new key: a new key would no longer
        // match the public key inside the issued credential.
        val privateKey = keyStore.getKey(ALIAS, null) as? PrivateKey ?: throw NoKeyException()
        return Signature.getInstance("SHA256withECDSA").run {
            initSign(privateKey)
            update(message)
            sign()
        }
    }

    private class NoKeyException : Exception("the device key does not exist")

    companion object {
        const val CHANNEL = "app.dcid.student_app/keystore"
        private const val ALIAS = "dcid_device_key_v1"
        private const val PROVIDER = "AndroidKeyStore"

        fun register(messenger: BinaryMessenger) {
            val channel = KeystoreChannel()
            MethodChannel(messenger, CHANNEL).setMethodCallHandler(channel::handle)
        }
    }
}
