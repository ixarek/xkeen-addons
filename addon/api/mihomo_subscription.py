"""Local UI extension: validated subscription replacement for home-tun."""
import copy
import threading
from urllib.parse import urlparse, parse_qs, urlencode, unquote

from bottle import request

_lock = threading.Lock()
NAME = "home-tun"


def convert_uri(uri):
    from core.clash_yaml import uri_to_clash_proxy
    parsed = urlparse(uri)
    query = parse_qs(parsed.query)
    xhttp = parsed.scheme == "vless" and query.get("type", [""])[0] in ("xhttp", "splithttp")
    if xhttp:
        query_tcp = dict(query, type=["tcp"])
        uri_tcp = parsed._replace(query=urlencode(query_tcp, doseq=True)).geturl()
        result = uri_to_clash_proxy(uri_tcp)
    else:
        result = uri_to_clash_proxy(uri)
    if result.get("ok"):
        proxy = result["proxy"]
        if parsed.fragment:
            proxy["name"] = unquote(parsed.fragment)
        if xhttp:
            proxy["network"] = "xhttp"
            proxy["xhttp-opts"] = {"path": query.get("path", ["/"])[0],
                                   "host": query.get("host", [""])[0],
                                   "mode": query.get("mode", ["auto"])[0]}
            if query.get("extra"):
                import json
                extra = json.loads(query["extra"][0])
                mapping = {"noGRPCHeader": "no-grpc-header", "xPaddingBytes": "x-padding-bytes",
                           "headers": "headers", "scMaxEachPostBytes": "sc-max-each-post-bytes",
                           "scMinPostsIntervalMs": "sc-min-posts-interval-ms",
                           "scMaxBufferedPosts": "sc-max-buffered-posts"}
                tuning_only = {'scMaxConcurrentPosts', 'scStreamUpServerSecs'}
                if not isinstance(extra, dict) or any(k not in mapping and k != 'xmux' and k not in tuning_only for k in extra):
                    return {"ok": False, "error": "Unsupported XHTTP extra options"}
                proxy["xhttp-opts"].update({mapping[k]: v for k, v in extra.items() if k in mapping})
                if extra.get('xmux'):
                    muxmap = {'maxConcurrency': 'max-concurrency', 'maxConnections': 'max-connections',
                              'cMaxReuseTimes': 'c-max-reuse-times', 'hMaxRequestTimes': 'h-max-request-times',
                              'hMaxReusableSecs': 'h-max-reusable-secs', 'hKeepAlivePeriod': 'h-keep-alive-period'}
                    if any(k not in muxmap for k in extra['xmux']):
                        return {'ok': False, 'error': 'Unsupported XHTTP XMUX options'}
                    proxy['xhttp-opts']['reuse-settings'] = {muxmap[k]: v for k, v in extra['xmux'].items()}
                if any(k in extra for k in tuning_only):
                    result['warning'] = 'Часть параметров производительности XHTTP использует значения Mihomo по умолчанию.'
    return result


def register(app):
    @app.get("/api/mihomo/home-subscription")
    def get_subscription():
        from core.config_manager import get_config_manager
        cm = get_config_manager()
        return {"ok": True, "url": cm.get("mihomo_subscription", "url", default="")}

    @app.post("/api/mihomo/home-subscription")
    def update_subscription():
        from core.config_manager import get_config_manager
        from core.subscription_importer import fetch_subscription, extract_items, _host_is_internal
        from core.clash_yaml import parse_yaml, dump_yaml
        from core.mihomo_manager import get_mihomo_manager
        cm = get_config_manager()
        body = request.json or {}
        url = str(body.get("url") or cm.get("mihomo_subscription", "url", default="")).strip()
        parsed = urlparse(url)
        if parsed.scheme != "https" or not parsed.hostname or _host_is_internal(parsed.hostname):
            return {"ok": False, "error": "Укажите HTTPS-ссылку подписки провайдера"}
        if not _lock.acquire(blocking=False):
            return {"ok": False, "error": "Обновление уже выполняется"}
        try:
            mgr = get_mihomo_manager()
            old = mgr.get_config(NAME)
            if not old.get("ok"):
                return {"ok": False, "error": "Начальная конфигурация ещё не установлена"}
            try:
                raw = fetch_subscription(url)
            except Exception:
                return {"ok": False, "error": "Подписка не скачалась. Проверьте ссылку и интернет; прежние серверы сохранены."}
            proxies, skipped, warnings = [], 0, set()
            try:
                data = parse_yaml(raw)
                if isinstance(data, dict) and isinstance(data.get("proxies"), list):
                    proxies = data["proxies"]
            except Exception:
                pass
            if not proxies:
                for item in extract_items(raw):
                    if item.get("type") != "uri":
                        continue
                    result = convert_uri(item["value"])
                    if result.get("ok"):
                        proxies.append(result["proxy"])
                        if result.get('warning'):
                            warnings.add(result['warning'])
                    else:
                        skipped += 1
            from core.mihomo_routing import _dedup_names
            proxies = _dedup_names(proxies)
            if not proxies:
                return {"ok": False, "error": "В подписке нет поддерживаемых серверов. Прежний список сохранён."}
            cfg = copy.deepcopy(parse_yaml(old["text"]))
            cfg.pop("proxy-providers", None)
            cfg["proxies"] = proxies
            cfg["proxy-groups"] = [{"name": "PROXY", "type": "select", "proxies": [p["name"] for p in proxies]}]
            text = dump_yaml(cfg)
            valid = mgr.validate_via_binary(NAME, text=text)
            if not valid.get("ok"):
                return {"ok": False, "error": "Mihomo не принял новые серверы. Прежняя конфигурация сохранена."}
            running = mgr.is_running(NAME)
            saved = mgr.save_config(NAME, text=text)
            if not saved.get("ok"):
                return {"ok": False, "error": "Не удалось сохранить конфигурацию"}
            if running and not mgr.restart(NAME).get("ok"):
                mgr.save_config(NAME, text=old["text"])
                restored = mgr.restart(NAME)
                return {"ok": False, "error": "Новая конфигурация не запустилась; восстановлена прежняя", "restored": bool(restored.get("ok"))}
            cm.set("mihomo_subscription", {"url": url})
            cm.save()
            return {"ok": True, "servers": len(proxies), "skipped": skipped, "restarted": running, "warnings": sorted(warnings)}
        except Exception:
            return {"ok": False, "error": "Ошибка обработки подписки. Проверьте формат."}
        finally:
            _lock.release()
