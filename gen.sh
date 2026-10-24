#!/usr/bin/env bash
set -euo pipefail

ROOT="${1:-AdStripper}"
rm -rf "$ROOT"
mkdir -p "$ROOT/.github/workflows"
mkdir -p "$ROOT/app/src/main/java/ai/venice/adstripper"

# ---- signing keystore (repo root pe, ek hi baar banta hai) ----------------
if [ ! -f keystore.jks ] && command -v keytool >/dev/null 2>&1; then
  keytool -genkeypair -v -keystore keystore.jks -alias adstripper \
    -keyalg RSA -keysize 2048 -validity 10000 \
    -storepass adstripper -keypass adstripper \
    -dname "CN=AdStripper, O=AdStripper, C=US"
fi

# ---- gradle ---------------------------------------------------------------
cat > "$ROOT/settings.gradle" <<'EOF'
pluginManagement {
    repositories { google(); mavenCentral(); gradlePluginPortal() }
}
dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    repositories { google(); mavenCentral() }
}
rootProject.name = "AdStripper"
include ':app'
EOF

cat > "$ROOT/build.gradle" <<'EOF'
tasks.register("clean", Delete) {
    delete rootProject.buildDir
}
EOF

cat > "$ROOT/gradle.properties" <<'EOF'
android.useAndroidX=true
org.gradle.jvmargs=-Xmx2048m
EOF

cat > "$ROOT/.gitignore" <<'EOF'
.gradle/
build/
local.properties
*.iml
.idea/
EOF

cat > "$ROOT/README.md" <<'EOF'
# AdStripper

Android app that strips ad SDKs out of any APK, on-device.

- Rewrites classes*.dex with dexlib2 (no apktool, no PC).
- Banner loadAd -> setVisibility(GONE) + return; full-screen load/show -> no-op.
- Repacks APK, re-aligns .so to 4096 and resources.arsc to 4, strips old
  META-INF signatures, signs v1+v2+v3 with apksig.
- Output: /sdcard/Android/data/ai.venice.adstripper/files/<name>-noads.apk
EOF

cat > "$ROOT/.github/workflows/build.yml" <<'YAML'
name: Build APK
on:
  push:
    branches: [ main, master ]
  workflow_dispatch:
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-java@v4
        with:
          distribution: temurin
          java-version: '17'
      - uses: gradle/actions/setup-gradle@v4
        with:
          gradle-version: '8.7'
      - run: gradle assembleDebug --no-daemon
      - uses: actions/upload-artifact@v4
        with:
          name: AdStripper-debug-apk
          path: app/build/outputs/apk/debug/*.apk
YAML

# ---- app gradle (signing + R8) -------------------------------------------
cat > "$ROOT/app/build.gradle" <<'EOF'
plugins { id 'com.android.application' version '8.1.4' }

android {
    namespace 'ai.venice.adstripper'
    compileSdk 34

    defaultConfig {
        applicationId "ai.venice.adstripper"
        minSdk 26
        targetSdk 34
        versionCode 1
        versionName "1.0"
    }

    compileOptions {
        sourceCompatibility JavaVersion.VERSION_17
        targetCompatibility JavaVersion.VERSION_17
    }

    packaging {
        resources {
            excludes += ['META-INF/versions/**', 'META-INF/DEPENDENCIES',
                         'META-INF/LICENSE*', 'META-INF/NOTICE*', 'META-INF/*.kotlin_module']
        }
    }

    signingConfigs {
        release {
            def ks = System.getenv("KEYSTORE") ?: rootProject.file("../keystore.jks").absolutePath
            storeFile file(ks)
            storePassword System.getenv("KEYSTORE_PASSWORD") ?: "adstripper"
            keyAlias      System.getenv("KEY_ALIAS")         ?: "adstripper"
            keyPassword   System.getenv("KEY_PASSWORD")      ?: "adstripper"
        }
    }

    buildTypes {
        release {
            minifyEnabled true
            shrinkResources true
            signingConfig signingConfigs.release
            proguardFiles getDefaultProguardFile('proguard-android-optimize.txt'), 'proguard-rules.pro'
        }
    }
}

dependencies {
    implementation('org.smali:dexlib2:2.5.2') { exclude group: 'com.google.guava' }
    implementation 'com.google.guava:guava:32.1.3-android'
    implementation 'com.android.tools.build:apksig:8.1.4'
    implementation 'org.bouncycastle:bcpkix-jdk15to18:1.77'
    implementation 'org.bouncycastle:bcprov-jdk15to18:1.77'
}
EOF

# ---- proguard -------------------------------------------------------------
cat > "$ROOT/app/proguard-rules.pro" <<'EOF'
-keepattributes *Annotation*, Signature, InnerClasses, EnclosingMethod

# Libraries lean on reflection heavily - keep them whole
-keep class org.jf.dexlib2.**        { *; }
-keep class com.android.apksig.**    { *; }
-keep class org.bouncycastle.**      { *; }
-keep class com.google.common.**    { *; }

-keep class ai.venice.adstripper.MainActivity { *; }

-dontwarn javax.annotation.**
-dontwarn javax.lang.model.**
-dontwarn javax.xml.**
-dontwarn java.beans.**
-dontwarn java.lang.management.**
-dontwarn sun.misc.**
-dontwarn org.w3c.dom.**
-dontwarn org.checkerframework.**
-dontwarn com.google.errorprone.annotations.**
-dontwarn com.google.j2objc.annotations.**
-dontwarn com.google.common.**
-dontwarn org.jf.dexlib2.**
-dontwarn com.android.apksig.**
-dontwarn org.bouncycastle.**
EOF

# ---- manifest -------------------------------------------------------------
cat > "$ROOT/app/src/main/AndroidManifest.xml" <<'EOF'
<?xml version="1.0" encoding="utf-8"?>
<manifest xmlns:android="http://schemas.android.com/apk/res/android">
    <application
        android:label="AdStripper"
        android:theme="@android:style/Theme.Material.Light.DarkActionBar">
        <activity android:name=".MainActivity" android:exported="true">
            <intent-filter>
                <action android:name="android.intent.action.MAIN"/>
                <category android:name="android.intent.category.LAUNCHER"/>
            </intent-filter>
        </activity>
    </application>
</manifest>
EOF

# ---- SdkRules -------------------------------------------------------------
cat > "$ROOT/app/src/main/java/ai/venice/adstripper/SdkRules.java" <<'EOF'
package ai.venice.adstripper;

import java.util.HashMap;
import java.util.Map;

/** Registry of ad networks, keyed by smali class descriptor. */
final class SdkRules {

    enum Action { HIDE, NOOP }

    private static final Map<String, Map<String, Action>> BANNERS = new HashMap<>();
    private static final Map<String, Map<String, Action>> INTERS  = new HashMap<>();

    private static void put(Map<String, Map<String, Action>> m, String cls, String... methods) {
        Map<String, Action> mm = m.computeIfAbsent("L" + cls + ";", k -> new HashMap<>());
        for (String s : methods) mm.put(s, m == BANNERS ? Action.HIDE : Action.NOOP);
    }

    static {
        put(BANNERS, "com/google/android/gms/ads/BaseAdView", "loadAd");
        put(BANNERS, "com/google/android/gms/ads/AdView", "loadAd");
        put(BANNERS, "com/google/android/gms/ads/admanager/AdManagerAdView", "loadAd");
        put(BANNERS, "com/facebook/ads/AdView", "loadAd");
        put(BANNERS, "com/facebook/ads/AdViewBase", "loadAd");
        put(BANNERS, "com/unity3d/ads/banner/BannerView", "load", "loadBanner");
        put(BANNERS, "com/applovin/adview/AppLovinAdView", "loadNextAd", "render");
        put(BANNERS, "com/mopub/mobileads/MoPubView", "loadAd");
        put(BANNERS, "com/inmobi/ads/InMobiBanner", "load");
        put(BANNERS, "com/ironsource/mediationsdk/ISBannerView", "loadBanner");
        put(BANNERS, "com/amazon/device/ads/AdLayout", "loadAd");
        put(BANNERS, "com/startapp/sdk/adsbase/StartAppAd", "loadAd");
        put(BANNERS, "com/smaato/soma/BannerView", "loadAd", "asyncLoadAd");

        put(INTERS, "com/google/android/gms/ads/BaseInterstitialAd", "loadAd", "load", "show", "showInterstitial");
        put(INTERS, "com/google/android/gms/ads/interstitial/InterstitialAd", "load", "loadAd", "show");
        put(INTERS, "com/facebook/ads/InterstitialAd", "loadAd", "show");
        put(INTERS, "com/unity3d/ads/UnityAds", "show");
        put(INTERS, "com/applovin/adview/AppLovinInterstitialAd", "show");
        put(INTERS, "com/applovin/adview/AppLovinInterstitialAdDialog", "show");
        put(INTERS, "com/mopub/mobileads/MoPubInterstitial", "load", "show");
        put(INTERS, "com/inmobi/ads/InMobiInterstitial", "load", "show");
        put(INTERS, "com/vungle/ads/VungleInterstitial", "loadAd", "playAd");
        put(INTERS, "com/vungle/ads/VungleAdvert", "loadAd", "playAd");
        put(INTERS, "com/chartboost/sdk/Chartboost", "showInterstitial");
        put(INTERS, "com/ironsource/mediationsdk/IronSource", "showInterstitial");
        put(INTERS, "com/amazon/device/ads/InterstitialAd", "loadAd", "show");
        put(INTERS, "com/adcolony/sdk/AdColony", "show");
        put(INTERS, "com/startapp/sdk/adsbase/StartAppAd", "showAd");
        put(INTERS, "com/smaato/soma/InterstitialAd", "loadAd", "show");
    }

    static Action actionFor(String descriptor, String method, boolean aggressive) {
        Map<String, Action> m = BANNERS.get(descriptor);
        if (m != null) { Action a = m.get(method); if (a != null) return a; }
        if (aggressive) {
            m = INTERS.get(descriptor);
            if (m != null) { Action a = m.get(method); if (a != null) return a; }
        }
        return null;
    }

    private SdkRules() { }
}
EOF

# ---- AdPatcher ------------------------------------------------------------
cat > "$ROOT/app/src/main/java/ai/venice/adstripper/AdPatcher.java" <<'EOF'
package ai.venice.adstripper;

import com.android.apksig.ApkSigner;

import org.bouncycastle.asn1.x500.X500Name;
import org.bouncycastle.cert.jcajce.JcaX509CertificateConverter;
import org.bouncycastle.cert.jcajce.JcaX509v3CertificateBuilder;
import org.bouncycastle.jce.provider.BouncyCastleProvider;
import org.bouncycastle.operator.ContentSigner;
import org.bouncycastle.operator.jcajce.JcaContentSignerBuilder;
import org.jf.dexlib2.DexFileFactory;
import org.jf.dexlib2.Opcode;
import org.jf.dexlib2.Opcodes;
import org.jf.dexlib2.builder.MethodImplementationBuilder;
import org.jf.dexlib2.builder.instruction.*;
import org.jf.dexlib2.iface.DexFile;
import org.jf.dexlib2.iface.Method;
import org.jf.dexlib2.iface.MethodImplementation;
import org.jf.dexlib2.immutable.reference.ImmutableMethodReference;
import org.jf.dexlib2.rewriter.*;

import java.io.*;
import java.math.BigInteger;
import java.security.KeyPair;
import java.security.KeyPairGenerator;
import java.security.KeyStore;
import java.security.PrivateKey;
import java.security.Provider;
import java.security.cert.Certificate;
import java.security.cert.X509Certificate;
import java.util.*;
import java.util.zip.*;

public final class AdPatcher {

    public interface Progress { void step(String message); }

    private static final Provider BC = new BouncyCastleProvider();

    private static final String VIEW = "Landroid/view/View;";
    private static final String META = "META-INF/";

    private AdPatcher() { }

    public static void patch(File inApk, File outApk, boolean aggressive, Progress p) throws Exception {
        Map<String, byte[]> patched = new LinkedHashMap<>();

        try (ZipFile zip = new ZipFile(inApk)) {
            Enumeration<? extends ZipEntry> e = zip.entries();
            while (e.hasMoreElements()) {
                ZipEntry ze = e.nextElement();
                if (isDex(ze.getName())) {
                    p.step("Patching " + ze.getName() + " ...");
                    patched.put(ze.getName(), patchDex(readAll(zip.getInputStream(ze)), aggressive));
                }
            }
        }
        if (patched.isEmpty()) throw new IOException("No classes.dex found in this APK.");

        File dir = outApk.getParentFile();
        File unsigned = new File(dir, outApk.getName() + ".unsigned");
        File signed   = new File(dir, outApk.getName() + ".signed");

        p.step("Repacking APK ...");
        repack(inApk, unsigned, patched);

        p.step("Signing APK ...");
        sign(unsigned, signed, new File(dir, "adstripper.p12"));
        unsigned.delete();

        if (outApk.exists()) outApk.delete();
        if (!signed.renameTo(outApk)) { copyFile(signed, outApk); signed.delete(); }
    }

    private static byte[] patchDex(byte[] raw, boolean aggressive) throws IOException {
        File in = File.createTempFile("adstrip_in", ".dex");
        File out = File.createTempFile("adstrip_out", ".dex");
        try {
            writeAll(in, raw);
            DexFile dex = DexFileFactory.loadDexFile(in, Opcodes.getDefault());
            DexFile rewritten = makeRewriter(aggressive).rewriteDexFile(dex);
            DexFileFactory.writeDexFile(out.getAbsolutePath(), rewritten);
            return readAll(new FileInputStream(out));
        } finally {
            in.delete();
            out.delete();
        }
    }

    private static DexRewriter makeRewriter(final boolean aggressive) {
        RewriterModule module = new RewriterModule() {
            @Override public MethodImplementationRewriter getMethodImplementationRewriter(Rewriters rewriters) {
                return (method, impl) -> {
                    if (impl == null) return null;
                    SdkRules.Action a = SdkRules.actionFor(method.getDefiningClass(), method.getName(), aggressive);
                    return a == null ? impl : stub(method, a);
                };
            }
        };
        return new DexRewriter(Collections.singletonList(module));
    }

    private static MethodImplementation stub(Method m, SdkRules.Action action) {
        int paramRegs = m.isStatic() ? 0 : 1;
        for (CharSequence t : m.getParameterTypes()) {
            String d = t.toString();
            paramRegs += (d.equals("J") || d.equals("D")) ? 2 : 1;
        }
        String ret = m.getReturnType();
        boolean wide = ret.equals("J") || ret.equals("D");
        int locals = wide ? 2 : 1;
        int total = paramRegs + locals;
        int v0 = 0;
        int thisReg = locals;

        MethodImplementationBuilder b = new MethodImplementationBuilder(total);

        if (action == SdkRules.Action.HIDE && !m.isStatic()) {
            b.addInstruction(new BuilderInstruction21s(Opcode.CONST_16, v0, 8));
            ImmutableMethodReference setVis = new ImmutableMethodReference(
                    VIEW, "setVisibility", Collections.singletonList("I"), "V");
            b.addInstruction(new BuilderInstruction35c(
                    Opcode.INVOKE_VIRTUAL, 2, thisReg, v0, 0, 0, 0, setVis));
        }

        if (ret.equals("V")) {
            b.addInstruction(new BuilderInstruction10x(Opcode.RETURN_VOID));
        } else if (wide) {
            b.addInstruction(new BuilderInstruction21s(Opcode.CONST_WIDE_16, v0, 0));
            b.addInstruction(new BuilderInstruction11x(Opcode.RETURN_WIDE, v0));
        } else if ("ZBSIC".contains(ret)) {
            b.addInstruction(new BuilderInstruction11n(Opcode.CONST_4, v0, 0));
            b.addInstruction(new BuilderInstruction11x(Opcode.RETURN, v0));
        } else {
            b.addInstruction(new BuilderInstruction11n(Opcode.CONST_4, v0, 0));
            b.addInstruction(new BuilderInstruction11x(Opcode.RETURN_OBJECT, v0));
        }
        return b.getMethodImplementation();
    }

    private static void repack(File in, File out, Map<String, byte[]> replacements) throws IOException {
        Counter counter = new Counter(new BufferedOutputStream(new FileOutputStream(out), 1 << 16));
        ZipOutputStream zos = new ZipOutputStream(counter);

        try (ZipFile zip = new ZipFile(in)) {
            Enumeration<? extends ZipEntry> en = zip.entries();
            while (en.hasMoreElements()) {
                ZipEntry src = en.nextElement();
                String name = src.getName();
                if (isOldSignature(name)) continue;

                ZipEntry dst = new ZipEntry(name);
                long t = src.getTime();
                if (t > 0) dst.setTime(t);

                byte[] data = null;
                if (replacements.containsKey(name)) {
                    data = replacements.get(name);
                    dst.setMethod(ZipEntry.DEFLATED);
                } else if (src.getMethod() == ZipEntry.STORED) {
                    data = readAll(zip.getInputStream(src));
                    dst.setMethod(ZipEntry.STORED);
                    dst.setSize(data.length);
                    dst.setCrc(crc32(data));
                } else {
                    dst.setMethod(ZipEntry.DEFLATED);
                }

                if (dst.getMethod() == ZipEntry.STORED) {
                    int align = name.endsWith(".so") ? 4096 : 4;
                    int base = (int) counter.count + 30 + utf8Len(name);
                    byte[] extra = alignExtra(base, align);
                    if (extra != null) dst.setExtra(extra);
                }

                zos.putNextEntry(dst);
                if (data != null) {
                    zos.write(data);
                } else {
                    try (InputStream is = zip.getInputStream(src)) {
                        byte[] buf = new byte[1 << 16];
                        int n;
                        while ((n = is.read(buf)) > 0) zos.write(buf, 0, n);
                    }
                }
                zos.closeEntry();
            }
        }
        zos.finish();
        zos.flush();
        counter.flush();
    }

    private static byte[] alignExtra(int base, int align) {
        int e = (align - (base % align)) % align;
        if (e == 0) return null;
        if (e < 4) e += align;
        byte[] extra = new byte[e];
        extra[0] = (byte) 0xCE; extra[1] = (byte) 0xFA;
        int payload = e - 4;
        extra[2] = (byte) (payload & 0xFF);
        extra[3] = (byte) ((payload >> 8) & 0xFF);
        return extra;
    }

    private static void sign(File in, File out, File ksFile) throws Exception {
        KeyStore ks = KeyStore.getInstance("PKCS12");
        char[] pass = "adstripper".toCharArray();

        PrivateKey key;
        List<X509Certificate> chain = new ArrayList<>();

        if (ksFile.exists()) {
            try (InputStream is = new FileInputStream(ksFile)) { ks.load(is, pass); }
            key = (PrivateKey) ks.getKey("adstripper", pass);
            for (Certificate c : ks.getCertificateChain("adstripper")) chain.add((X509Certificate) c);
        } else {
            KeyPairGenerator kpg = KeyPairGenerator.getInstance("RSA");
            kpg.initialize(2048);
            KeyPair kp = kpg.generateKeyPair();

            long now = System.currentTimeMillis();
            X500Name dn = new X500Name("CN=AdStripper, O=AdStripper, C=US");
            JcaX509v3CertificateBuilder cb = new JcaX509v3CertificateBuilder(
                    dn, BigInteger.ONE, new Date(now - 86_400_000L),
                    new Date(now + 30L * 365 * 86_400_000L), dn, kp.getPublic());
            ContentSigner cs = new JcaContentSignerBuilder("SHA256withRSA")
                    .setProvider(BC).build(kp.getPrivate());
            X509Certificate cert = new JcaX509CertificateConverter()
                    .setProvider(BC).getCertificate(cb.build(cs));

            key = kp.getPrivate();
            chain.add(cert);

            ks.load(null, pass);
            ks.setKeyEntry("adstripper", key, pass, new Certificate[]{cert});
            try (OutputStream os = new FileOutputStream(ksFile)) { ks.store(os, pass); }
        }

        ApkSigner.SignerConfig cfg = new ApkSigner.SignerConfig.Builder("adstripper", key, chain).build();
        new ApkSigner.Builder(Collections.singletonList(cfg))
                .setInputApk(in)
                .setOutputApk(out)
                .setV1SigningEnabled(true)
                .setV2SigningEnabled(true)
                .setV3SigningEnabled(true)
                .build()
                .sign();
    }

    private static boolean isDex(String name) {
        return name.matches("^classes\\d*\\.dex$");
    }

    private static boolean isOldSignature(String name) {
        String u = name.toUpperCase(Locale.ROOT);
        if (!u.startsWith(META)) return false;
        return u.endsWith(".SF") || u.endsWith(".RSA") || u.endsWith(".DSA")
                || u.endsWith(".EC") || u.equals(META + "MANIFEST.MF");
    }

    private static int utf8Len(String s) {
        int n = 0;
        for (int i = 0; i < s.length(); i++) {
            char c = s.charAt(i);
            n += c < 0x80 ? 1 : c < 0x800 ? 2 : 3;
        }
        return n;
    }

    private static long crc32(byte[] d) {
        CRC32 c = new CRC32();
        c.update(d);
        return c.getValue();
    }

    private static byte[] readAll(InputStream is) throws IOException {
        ByteArrayOutputStream bos = new ByteArrayOutputStream();
        byte[] buf = new byte[1 << 16];
        int n;
        while ((n = is.read(buf)) > 0) bos.write(buf, 0, n);
        return bos.toByteArray();
    }

    private static void writeAll(File f, byte[] d) throws IOException {
        try (OutputStream os = new FileOutputStream(f)) { os.write(d); }
    }

    private static void copyFile(File a, File b) throws IOException {
        try (InputStream is = new FileInputStream(a); OutputStream os = new FileOutputStream(b)) {
            byte[] buf = new byte[1 << 16];
            int n;
            while ((n = is.read(buf)) > 0) os.write(buf, 0, n);
        }
    }

    private static final class Counter extends FilterOutputStream {
        long count;
        Counter(OutputStream out) { super(out); }
        @Override public void write(int b) throws IOException { out.write(b); count++; }
        @Override public void write(byte[] b, int off, int len) throws IOException {
            out.write(b, off, len); count += len;
        }
    }
}
EOF

# ---- MainActivity ---------------------------------------------------------
cat > "$ROOT/app/src/main/java/ai/venice/adstripper/MainActivity.java" <<'EOF'
package ai.venice.adstripper;

import android.app.Activity;
import android.content.Intent;
import android.database.Cursor;
import android.net.Uri;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.provider.OpenableColumns;
import android.view.View;
import android.widget.*;

import java.io.*;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

public class MainActivity extends Activity {

    private static final int REQ_PICK = 1001;

    private final Handler ui = new Handler(Looper.getMainLooper());
    private final ExecutorService pool = Executors.newSingleThreadExecutor();

    private TextView status;
    private ProgressBar bar;
    private Button pick;

    @Override
    protected void onCreate(Bundle saved) {
        super.onCreate(saved);

        float d = getResources().getDisplayMetrics().density;
        int pad = (int) (16 * d);

        LinearLayout root = new LinearLayout(this);
        root.setOrientation(LinearLayout.VERTICAL);
        root.setPadding(pad, pad, pad, pad);

        TextView title = new TextView(this);
        title.setText("AdStripper");
        title.setTextSize(26);
        root.addView(title);

        TextView sub = new TextView(this);
        sub.setText("Pick an APK. Its ad code gets neutralised, then the APK is rebuilt and signed.");
        sub.setPadding(0, pad / 2, 0, pad);
        root.addView(sub);

        pick = new Button(this);
        pick.setText("Pick an APK file");
        pick.setOnClickListener(v -> pickApk());
        root.addView(pick);

        bar = new ProgressBar(this, null, android.R.attr.progressBarStyleHorizontal);
        bar.setIndeterminate(true);
        bar.setVisibility(View.GONE);
        LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT);
        lp.topMargin = pad / 2;
        root.addView(bar, lp);

        status = new TextView(this);
        status.setTextIsSelectable(true);
        status.setPadding(0, pad, 0, 0);
        root.addView(status);

        setContentView(root);
    }

    private void pickApk() {
        Intent i = new Intent(Intent.ACTION_OPEN_DOCUMENT);
        i.addCategory(Intent.CATEGORY_OPENABLE);
        i.setType("*/*");
        startActivityForResult(i, REQ_PICK);
    }

    @Override
    protected void onActivityResult(int req, int res, Intent data) {
        super.onActivityResult(req, res, data);
        if (req != REQ_PICK || res != RESULT_OK || data == null || data.getData() == null) return;

        final Uri uri = data.getData();
        final String display = queryName(uri);

        pick.setEnabled(false);
        bar.setVisibility(View.VISIBLE);
        status.setText("Preparing...");

        pool.execute(() -> {
            try {
                File inApk = new File(getCacheDir(), "input.apk");
                try (InputStream in = getContentResolver().openInputStream(uri);
                     OutputStream out = new FileOutputStream(inApk)) {
                    if (in == null) throw new IllegalStateException("cannot open " + uri);
                    byte[] buf = new byte[1 << 16];
                    int n;
                    while ((n = in.read(buf)) > 0) out.write(buf, 0, n);
                }

                String base = display.toLowerCase().endsWith(".apk")
                        ? display.substring(0, display.length() - 4) : display;
                File outApk = new File(getExternalFilesDir(null), base + "-noads.apk");
                if (outApk.exists()) outApk = new File(getExternalFilesDir(null), base + "-noads-2.apk");

                final File result = outApk;
                AdPatcher.patch(inApk, outApk, true, msg -> ui.post(() -> status.setText(msg)));

                ui.post(() -> {
                    bar.setVisibility(View.GONE);
                    pick.setEnabled(true);
                    status.setText("Done.\n\nSaved:\n" + result.getAbsolutePath()
                            + "\n\nUninstall the original app first, then install this file.");
                });
            } catch (Throwable t) {
                ui.post(() -> {
                    bar.setVisibility(View.GONE);
                    pick.setEnabled(true);
                    status.setText("Failed:\n" + t);
                });
            }
        });
    }

    private String queryName(Uri uri) {
        try (Cursor c = getContentResolver().query(uri, null, null, null, null)) {
            if (c != null && c.moveToFirst()) {
                int i = c.getColumnIndex(OpenableColumns.DISPLAY_NAME);
                if (i >= 0) {
                    String s = c.getString(i);
                    if (s != null && !s.isEmpty()) return s;
                }
            }
        } catch (Exception ignored) { }
        return "app.apk";
    }
}
EOF

echo "Banaya: $ROOT"

if command -v zip >/dev/null 2>&1; then
  if [ -f keystore.jks ]; then
    zip -qr "$ROOT.zip" "$ROOT" keystore.jks
  else
    zip -qr "$ROOT.zip" "$ROOT"
  fi
  echo "Zip ready: $ROOT.zip"
fi
