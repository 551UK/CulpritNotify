"""Run the production Objective-C report parser with Foundation on macOS."""
import json
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
source = (root / 'Tweak.xm').read_text()
parser = source[source.index('static NSDictionary *CNJSONDictionary'):source.index('static void CNTrimRecent')]
harness = r'''
int main(int argc, const char **argv) {
    @autoreleasepool {
        NSDictionary *result = CNBuildNotificationForReport(@(argv[1]));
        NSData *json = [NSJSONSerialization dataWithJSONObject:result options:0 error:nil];
        puts([[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding].UTF8String);
    }
}
'''

def ips(body, bug='309'):
    return json.dumps({'app_name': 'Example', 'bug_type': bug}) + '\n' + json.dumps(body)

# Minimal reproduction of the supplied TikTok report, without device identifiers.
wakeups = '{"app_name":"TikTok","bug_type":"142"}\nEvent:            wakeups\nAction taken:     none\nWakeups:          45001 wakeups over the last 136 seconds (331 wakeups per second average)\n'
cases = [
    ('TikTok.wakeups_resource.ips', wakeups, 'TikTok wakeups warning', 'iOS took no action'),
    ('Renamed.ips', wakeups, 'TikTok wakeups warning', 'iOS took no action'),
    ('Example.cpu_resource.ips', 'Command: Example\nEvent: cpu usage\nAction taken: none\n', 'Example CPU warning', 'iOS took no action'),
    ('Example.memory_resource.ips', 'Command: Example\nAction taken: none\n', 'Example memory warning', 'iOS took no action'),
    ('Example.wakeups_resource.ips', 'Command: Example\nAction taken: terminated\n', 'Example wakeups termination', 'terminated the process'),
    ('Example.cpu_resource.ips', 'Command: Example\nEvent: cpu usage\n', 'Example CPU report', 'not confirmed'),
    ('Example.ips', ips({'exception': {'type': 'EXC_BAD_ACCESS'}, 'faultingThread': 0}), 'Example crashed', 'EXC_BAD_ACCESS'),
    ('Example.crash', 'Process: Example\nException Type: EXC_BAD_ACCESS (SIGSEGV)\n', 'Example crashed', 'EXC_BAD_ACCESS'),
    ('Example.ips', ips({'threads': []}), 'Example diagnostic report', 'diagnostic report'),
    ('Example.ips', ips({'exception': {'type': 'EXC_RESOURCE'}}), 'Example resource report', 'not confirmed'),
    ('JetsamEvent.ips', ips({'largestProcess': 'Example'}, '298'), 'Jetsam: Example', 'Memory-pressure'),
    ('Example.ips', json.dumps({'procName': 'Example', 'exception': {'type': 'EXC_BAD_ACCESS'}}, indent=2), 'Example crashed', 'EXC_BAD_ACCESS'),
    ('Example.ips', ips({}) + '\nAction taken: none\n/var/jb/Library/MobileSubstrate/DynamicLibraries/SomeTweak.dylib\n', 'Example resource warning', 'iOS took no action'),
]
with tempfile.TemporaryDirectory() as tmp:
    folder = Path(tmp)
    m = folder / 'parser.m'
    m.write_text('#import <Foundation/Foundation.h>\n' + parser + harness)
    binary = folder / 'parser'
    subprocess.run(['xcrun', 'clang', '-fobjc-arc', '-fblocks', '-Wno-incompatible-pointer-types', '-framework', 'Foundation', str(m), '-o', str(binary)], check=True)
    for name, content, title, message in cases:
        report = folder / name
        report.write_text(content)
        result = json.loads(subprocess.check_output([str(binary), str(report)], text=True))
        assert result['title'] == title, (name, result, title)
        assert message in result['message'], (name, result, message)
        if 'warning' in title:
            assert 'Culprit:' not in result['message'], result
        print('PASS:', title)
print(f'{len(cases)} report classification tests passed')
