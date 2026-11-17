"""Static check of a Sandpiper APK (run by build-sandpiper-android.sh, or by hand):

    python -I check-sandpiper-apk.py <aapt2> <apk> [--report out.md]

1. Identity: no forbidden substring (VPN client names) in the package name, authorities, custom
   action names, data schemes and component names (system names Android requires are allowed:
   android.net.VpnService, android.permission.BIND_VPN_SERVICE, ...).
2. Lists every exported component with its intent filters (actions, categories, schemes, hosts)
   and its permission.
Exit 1 when a forbidden substring is found.
"""
import re
import subprocess
import sys

FORBIDDEN = ['vpn', 'wireguard', 'v2ray', 'xray', 'clash', 'shadowsocks', 'amnezia', 'hiddify', 'nb4a',
             'outline', 'tor', 'psiphon', 'happ', 'byedpi', 'strongswan', 'lantern', 'sing-box', 'singbox']
# required by Android or by libraries, not chosen by the app
ALLOWED = {
    'android.net.VpnService',
    'android.permission.BIND_VPN_SERVICE',
    'android.net.VpnService.SUPPORTS_ALWAYS_ON',
}


def xmltree(aapt2, apk):
    return subprocess.run([aapt2, 'dump', 'xmltree', '--file', 'AndroidManifest.xml', apk],
                          capture_output=True, text=True, check=True).stdout


def parse(tree):
    """A light walk over aapt2's xmltree: elements with depth and their attributes."""
    elements = []
    for line in tree.splitlines():
        m = re.match(r'^(\s*)E: (\S+)', line)
        if m:
            elements.append({'depth': len(m.group(1)), 'tag': m.group(2), 'attrs': {}})
            continue
        m = re.match(r'^\s*A: (?:http://schemas.android.com/apk/res/android:)?([\w:]+)\(0x[0-9a-f]+\)=(.*)$', line) or \
            re.match(r'^\s*A: (?:http://schemas.android.com/apk/res/android:)?([\w:]+)=(.*)$', line)
        if m and elements:
            value = m.group(2)
            raw = re.search(r'\(Raw: "(.*)"\)', value)
            value = raw.group(1) if raw else value.strip('"')
            elements[-1]['attrs'][m.group(1)] = value
    return elements


def check(aapt2, apk):
    tree = xmltree(aapt2, apk)
    elements = parse(tree)
    problems = []
    package = next((e['attrs'].get('package') for e in elements if e['tag'] == 'manifest'), '')

    def scan(kind, value):
        if not value or value in ALLOWED:
            return
        low = value.lower()
        for word in FORBIDDEN:
            if word == 'tor':
                hit = re.search(r'(^|[._\-/:])tor([._\-/:]|$)', low) is not None
            else:
                hit = word in low
            if hit:
                problems.append(f'{kind} "{value}" contains "{word}"')

    scan('package', package)
    components = []
    current = None
    for i, e in enumerate(elements):
        a = e['attrs']
        if e['tag'] in ('activity', 'activity-alias', 'service', 'receiver', 'provider'):
            name = a.get('name', '')
            if name.startswith('.'):
                name = package + name
            current = {'kind': e['tag'], 'name': name, 'exported': a.get('exported', ''),
                       'permission': a.get('permission', ''), 'authorities': a.get('authorities', ''),
                       'filters': [], 'depth': e['depth']}
            components.append(current)
            scan(e['tag'], name)
            for auth in a.get('authorities', '').split(';'):
                scan('authority', auth)
        elif current is not None and e['depth'] <= current['depth']:
            current = None
        if current is None:
            continue
        if e['tag'] == 'intent-filter':
            current['filters'].append({'action': [], 'category': [], 'scheme': [], 'host': []})
        elif e['tag'] in ('action', 'category') and current['filters']:
            current['filters'][-1][e['tag']].append(a.get('name', ''))
            if e['tag'] == 'action' and not a.get('name', '').startswith('android.'):
                scan('action', a.get('name', ''))
        elif e['tag'] == 'data' and current['filters']:
            for key in ('scheme', 'host'):
                if key in a:
                    current['filters'][-1][key].append(a[key])
                    scan(key, a[key])
    return package, components, problems


def main():
    aapt2, apk = sys.argv[1], sys.argv[2]
    report = sys.argv[sys.argv.index('--report') + 1] if '--report' in sys.argv else None
    package, components, problems = check(aapt2, apk)
    lines = [f'# Manifest of {apk.split("/")[-1].split(chr(92))[-1]}', '', f'package: `{package}`', '',
             '| kind | component | exported | permission | intent filters |', '|---|---|---|---|---|']
    for c in components:
        exported = c['exported'] in ('true', '0xffffffff', '-1')
        has_filters = bool(c['filters'])
        # an activity/service/receiver with filters and no explicit exported is exported before API 31
        if not exported and not has_filters:
            continue
        filters = '<br>'.join(
            ', '.join(x for x in (
                'actions: ' + ' '.join(f['action']) if f['action'] else '',
                'categories: ' + ' '.join(f['category']) if f['category'] else '',
                'schemes: ' + ' '.join(f['scheme']) if f['scheme'] else '',
                'hosts: ' + ' '.join(f['host']) if f['host'] else '',
            ) if x) for f in c['filters']) or '-'
        lines.append(f"| {c['kind']} | `{c['name']}` | {'yes' if exported else 'no (filters only)'} | "
                     f"{c['permission'] or '-'} | {filters} |")
    lines += ['', '## Forbidden substrings', '']
    lines += [f'- {p}' for p in problems] if problems else ['none']
    text = '\n'.join(lines) + '\n'
    if report:
        open(report, 'w', encoding='utf-8').write(text)
    sys.stdout.buffer.write(text.encode('utf-8'))
    sys.exit(1 if problems else 0)


if __name__ == '__main__':
    main()
