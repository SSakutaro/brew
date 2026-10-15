#!/usr/bin/env python3
"""Add diagnostics to a disposable runner without changing retry behaviour."""

from pathlib import Path
import sys

source = Path(sys.argv[1])
contents = source.read_text()
replacements = {
    '          r = system_command("find", args: [".", "-print0"], chdir: pathname, print_stderr: false)\n': '''          r = system_command("find", args: [".", "-print0"], chdir: pathname, print_stderr: false)
          warn "[dmg-probe] time=#{Time.now.utc.iso8601(6)} find command=#{r.command.inspect} status=#{r.status.inspect} bytes=#{r.stdout.bytesize} stderr=#{r.stderr.inspect} mount=#{pathname}"
''',
    '        raise EmptyError, pathname if bom_paths.empty?\n': '''        if bom_paths.empty?
          begin
            warn "[dmg-probe] failed mount realpath=#{pathname.realpath} stat=#{pathname.stat.inspect} children=#{Dir.children(pathname).first(8).inspect}"
          rescue SystemCallError => probe_error
            warn "[dmg-probe] failed mount inspection=#{probe_error.class}: #{probe_error.message}"
          end
          raise EmptyError, pathname
        end
''',
    '        # If mounting without agreeing to EULA succeeded, there is none.\n': '''        warn "[dmg-probe] time=#{Time.now.utc.iso8601(6)} attach status=#{without_eula.status.inspect} stderr=#{without_eula.stderr.inspect} stdout=#{without_eula.stdout.byteslice(0, 5000).inspect}"

        # If mounting without agreeing to EULA succeeded, there is none.
''',
    '            mount.eject(verbose:)\n': '''            warn "[dmg-probe] time=#{Time.now.utc.iso8601(6)} parent pid=#{Process.pid} error=#{$!.class} path=#{mount.path} exists=#{mount.path.exist?}"
            unless mount.path.exist?
              warn "[dmg-probe] parent mount table=#{system_command('/sbin/mount', print_stderr: false).stdout.inspect}"
            end
            mount.eject(verbose:)
''',
}
for before, after in replacements.items():
    if contents.count(before) != 1:
        raise SystemExit(f"Expected exactly one occurrence of {before!r}")
    contents = contents.replace(before, after)
source.write_text(contents)
