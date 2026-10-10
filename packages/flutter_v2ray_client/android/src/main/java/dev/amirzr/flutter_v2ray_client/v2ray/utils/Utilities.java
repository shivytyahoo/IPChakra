package dev.amirzr.flutter_v2ray_client.v2ray.utils;

import android.content.Context;
import android.util.Log;

import dev.amirzr.flutter_v2ray_client.v2ray.core.V2rayCoreManager;

import org.json.JSONArray;
import org.json.JSONObject;

import java.io.File;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.util.ArrayList;

public class Utilities {

    public static void CopyFiles(InputStream src, File dst) throws IOException {
        try (OutputStream out = new FileOutputStream(dst)) {
            byte[] buf = new byte[1024];
            int len;
            while ((len = src.read(buf)) > 0) {
                out.write(buf, 0, len);
            }
        }
    }

    public static String getUserAssetsPath(Context context) {
        File extDir = context.getExternalFilesDir("assets");
        if (extDir == null) {
            return "";
        }
        if (!extDir.exists()) {
            return context.getDir("assets", 0).getAbsolutePath();
        } else {
            return extDir.getAbsolutePath();
        }
    }

    public static void copyAssets(final Context context) {
        String extFolder = getUserAssetsPath(context);
        try {
            String geo = "geosite.dat,geoip.dat";
            for (String assets_obj : context.getAssets().list("")) {
                if (geo.contains(assets_obj)) {
                    CopyFiles(context.getAssets().open(assets_obj), new File(extFolder, assets_obj));
                }
            }
        } catch (Exception e) {
            Log.e("Utilities", "copyAssets failed=>", e);
        }
    }


    public static String convertIntToTwoDigit(int value) {
        if (value < 10) return "0" + value;
        else return value + "";
    }

    /**
     * Sanitize JSON for current Xray core before load/measure:
     * - strip removed {@code allowInsecure}
     * - migrate freedom {@code settings.domainStrategy} → {@code streamSettings.sockopt.domainStrategy}
     */
    public static String stripRemovedTlsOptions(String config) {
        if (config == null || config.isEmpty()) {
            return config;
        }
        try {
            JSONObject json = new JSONObject(config);
            stripAllowInsecureRecursive(json);
            migrateFreedomDomainStrategy(json);
            return json.toString();
        } catch (Exception e) {
            return config;
        }
    }

    private static void stripAllowInsecureRecursive(Object node) {
        if (node instanceof JSONObject) {
            JSONObject obj = (JSONObject) node;
            obj.remove("allowInsecure");
            JSONArray names = obj.names();
            if (names == null) {
                return;
            }
            for (int i = 0; i < names.length(); i++) {
                try {
                    stripAllowInsecureRecursive(obj.get(names.getString(i)));
                } catch (Exception ignored) {
                }
            }
        } else if (node instanceof JSONArray) {
            JSONArray arr = (JSONArray) node;
            for (int i = 0; i < arr.length(); i++) {
                try {
                    stripAllowInsecureRecursive(arr.get(i));
                } catch (Exception ignored) {
                }
            }
        }
    }

    private static void migrateFreedomDomainStrategy(JSONObject root) {
        if (!root.has("outbounds")) {
            return;
        }
        try {
            JSONArray outbounds = root.getJSONArray("outbounds");
            for (int i = 0; i < outbounds.length(); i++) {
                JSONObject outbound = outbounds.optJSONObject(i);
                if (outbound == null) {
                    continue;
                }
                if (!"freedom".equalsIgnoreCase(outbound.optString("protocol", ""))) {
                    continue;
                }
                JSONObject settings = outbound.optJSONObject("settings");
                if (settings == null || !settings.has("domainStrategy")) {
                    continue;
                }
                String strategy = settings.optString("domainStrategy", "");
                settings.remove("domainStrategy");
                if (strategy.isEmpty()) {
                    continue;
                }
                if ("UseIp".equalsIgnoreCase(strategy)) {
                    strategy = "UseIP";
                }
                JSONObject streamSettings = outbound.optJSONObject("streamSettings");
                if (streamSettings == null) {
                    streamSettings = new JSONObject();
                    outbound.put("streamSettings", streamSettings);
                }
                JSONObject sockopt = streamSettings.optJSONObject("sockopt");
                if (sockopt == null) {
                    sockopt = new JSONObject();
                    streamSettings.put("sockopt", sockopt);
                }
                if (!sockopt.has("domainStrategy")) {
                    sockopt.put("domainStrategy", strategy);
                }
            }
        } catch (Exception ignored) {
        }
    }

    public static V2rayConfig parseV2rayJsonFile(final String remark, String config, final ArrayList<String> blockedApplication, final ArrayList<String> bypass_subnets) {
        final V2rayConfig v2rayConfig = new V2rayConfig();
        v2rayConfig.REMARK = remark;
        v2rayConfig.BLOCKED_APPS = blockedApplication;
        v2rayConfig.BYPASS_SUBNETS = bypass_subnets;
        v2rayConfig.APPLICATION_ICON = AppConfigs.APPLICATION_ICON;
        v2rayConfig.APPLICATION_NAME = AppConfigs.APPLICATION_NAME;
        v2rayConfig.NOTIFICATION_DISCONNECT_BUTTON_NAME = AppConfigs.NOTIFICATION_DISCONNECT_BUTTON_NAME;
        config = stripRemovedTlsOptions(config);
        try {
            JSONObject config_json = new JSONObject(config);
            try {
                JSONArray inbounds = config_json.getJSONArray("inbounds");
                for (int i = 0; i < inbounds.length(); i++) {
                    try {
                        if (inbounds.getJSONObject(i).getString("protocol").equals("socks")) {
                            v2rayConfig.LOCAL_SOCKS5_PORT = inbounds.getJSONObject(i).getInt("port");
                        }
                    } catch (Exception e) {
                        //ignore
                    }
                    try {
                        if (inbounds.getJSONObject(i).getString("protocol").equals("http")) {
                            v2rayConfig.LOCAL_HTTP_PORT = inbounds.getJSONObject(i).getInt("port");
                        }
                    } catch (Exception e) {
                        //ignore
                    }
                }
            } catch (Exception e) {
                Log.w(V2rayCoreManager.class.getSimpleName(), "startCore warn => can`t find inbound port of socks5 or http.");
                return null;
            }
            try {
                v2rayConfig.CONNECTED_V2RAY_SERVER_ADDRESS = config_json.getJSONArray("outbounds")
                        .getJSONObject(0).getJSONObject("settings")
                        .getJSONArray("vnext").getJSONObject(0)
                        .getString("address");
                v2rayConfig.CONNECTED_V2RAY_SERVER_PORT = config_json.getJSONArray("outbounds")
                        .getJSONObject(0).getJSONObject("settings")
                        .getJSONArray("vnext").getJSONObject(0)
                        .getString("port");
            } catch (Exception e) {
                v2rayConfig.CONNECTED_V2RAY_SERVER_ADDRESS = config_json.getJSONArray("outbounds")
                        .getJSONObject(0).getJSONObject("settings")
                        .getJSONArray("servers").getJSONObject(0)
                        .getString("address");
                v2rayConfig.CONNECTED_V2RAY_SERVER_PORT = config_json.getJSONArray("outbounds")
                        .getJSONObject(0).getJSONObject("settings")
                        .getJSONArray("servers").getJSONObject(0)
                        .getString("port");
            }
            try {
                if (config_json.has("policy")) {
                    config_json.remove("policy");
                }
                if (config_json.has("stats")) {
                    config_json.remove("stats");
                }
            } catch (Exception ignore_error) {
                //ignore
            }
            if (AppConfigs.ENABLE_TRAFFIC_AND_SPEED_STATICS) {
                try {
                    JSONObject policy = new JSONObject();
                    JSONObject levels = new JSONObject();
                    levels.put("8", new JSONObject()
                            .put("connIdle", 300)
                            .put("downlinkOnly", 1)
                            .put("handshake", 4)
                            .put("uplinkOnly", 1));
                    JSONObject system = new JSONObject()
                            .put("statsOutboundUplink", true)
                            .put("statsOutboundDownlink", true);
                    policy.put("levels", levels);
                    policy.put("system", system);
                    config_json.put("policy", policy);
                    config_json.put("stats", new JSONObject());
                    config = config_json.toString();
                    v2rayConfig.ENABLE_TRAFFIC_STATICS = true;
                } catch (Exception e) {
                    //ignore
                }
            }
        } catch (Exception e) {
            Log.e(Utilities.class.getName(), "parseV2rayJsonFile failed => ", e);
            //ignore
            return null;
        }
        v2rayConfig.V2RAY_FULL_JSON_CONFIG = config;
        return v2rayConfig;
    }

    /**
     * Injects an Xray built-in TUN inbound so LibXrayLite can consume VpnService FD via
     * {@code startLoop(config, tunFd)}. Required for VPN mode with modern AndroidLibXrayLite.
     */
    public static String ensureTunInbound(String config, int mtu) {
        if (config == null || config.isEmpty()) {
            return config;
        }
        try {
            JSONObject json = new JSONObject(config);
            JSONArray inbounds = json.optJSONArray("inbounds");
            if (inbounds == null) {
                inbounds = new JSONArray();
                json.put("inbounds", inbounds);
            }
            boolean hasTun = false;
            for (int i = 0; i < inbounds.length(); i++) {
                JSONObject inbound = inbounds.optJSONObject(i);
                if (inbound != null && "tun".equalsIgnoreCase(inbound.optString("protocol", ""))) {
                    hasTun = true;
                    JSONObject settings = inbound.optJSONObject("settings");
                    if (settings == null) {
                        settings = new JSONObject();
                        inbound.put("settings", settings);
                    }
                    settings.put("MTU", mtu);
                    JSONObject sniffing = inbound.optJSONObject("sniffing");
                    if (sniffing == null) {
                        sniffing = new JSONObject();
                        inbound.put("sniffing", sniffing);
                    }
                    sniffing.put("enabled", true);
                    if (!sniffing.has("destOverride") || sniffing.isNull("destOverride")) {
                        sniffing.put("destOverride", new JSONArray()
                                .put("http")
                                .put("tls")
                                .put("quic"));
                    }
                    break;
                }
            }
            if (!hasTun) {
                JSONObject tunInbound = new JSONObject();
                tunInbound.put("tag", "tun");
                tunInbound.put("protocol", "tun");
                tunInbound.put("settings", new JSONObject()
                        .put("name", "xray0")
                        .put("MTU", mtu)
                        .put("userLevel", 8));
                tunInbound.put("sniffing", new JSONObject()
                        .put("enabled", true)
                        .put("destOverride", new JSONArray()
                                .put("http")
                                .put("tls")
                                .put("quic")));
                inbounds.put(tunInbound);
            }

            // Prefer IPv4 and keep DNS working under VPN.
            JSONObject dns = json.optJSONObject("dns");
            if (dns == null) {
                dns = new JSONObject();
                json.put("dns", dns);
            }
            if (!dns.has("queryStrategy")) {
                dns.put("queryStrategy", "UseIPv4");
            }
            if (!dns.has("servers") || dns.isNull("servers")) {
                dns.put("servers", new JSONArray()
                        .put("1.1.1.1")
                        .put("8.8.8.8"));
            }

            JSONObject routing = json.optJSONObject("routing");
            if (routing == null) {
                routing = new JSONObject();
                json.put("routing", routing);
            }
            if (!routing.has("domainStrategy") || routing.isNull("domainStrategy")) {
                routing.put("domainStrategy", "AsIs");
            }
            JSONArray rules = routing.optJSONArray("rules");
            if (rules == null) {
                rules = new JSONArray();
                routing.put("rules", rules);
            }
            boolean hasDnsRule = false;
            for (int i = 0; i < rules.length(); i++) {
                JSONObject rule = rules.optJSONObject(i);
                if (rule == null) {
                    continue;
                }
                String port = String.valueOf(rule.opt("port"));
                if ("direct".equals(rule.optString("outboundTag")) && port.contains("853")) {
                    hasDnsRule = true;
                    break;
                }
            }
            if (!hasDnsRule) {
                JSONArray newRules = new JSONArray();
                newRules.put(new JSONObject()
                        .put("type", "field")
                        .put("port", "53,853")
                        .put("outboundTag", "direct"));
                newRules.put(new JSONObject()
                        .put("type", "field")
                        .put("ip", new JSONArray()
                                .put("1.1.1.1")
                                .put("1.0.0.1")
                                .put("8.8.8.8")
                                .put("8.8.4.4"))
                        .put("outboundTag", "direct"));
                for (int i = 0; i < rules.length(); i++) {
                    newRules.put(rules.get(i));
                }
                routing.put("rules", newRules);
            }

            return json.toString();
        } catch (Exception e) {
            Log.e(Utilities.class.getName(), "ensureTunInbound failed", e);
            return config;
        }
    }


}
