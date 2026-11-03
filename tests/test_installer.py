"""Isolated checks, never install services or require a clean OS."""
import os, pathlib, subprocess, tempfile, unittest, json, tarfile, io
ROOT=pathlib.Path(__file__).resolve().parents[1]
SCRIPT=ROOT/'openflux-setup.sh'
def shell(body, cwd=None):
    return subprocess.run(['bash','-c',f'source "{SCRIPT}"\n'+body],cwd=cwd,text=True,capture_output=True)
class InstallerTests(unittest.TestCase):
    def test_diagnosis_does_not_invent_traffic(self):
        r=shell("printf '%s\\n' 'active' | diagnose_text")
        self.assertEqual(r.returncode,0,r.stderr)
        self.assertIn('не проверена',r.stdout)
    def test_diagnosis_recognizes_captcha_and_protocol(self):
        r=shell("printf '%s\\n' 'captcha required' 'classic-mode frames' '[STRIPE] gave up' | diagnose_text")
        self.assertEqual(r.returncode,0,r.stderr)
        for word in ('капча','протокол','потер'): self.assertIn(word,r.stdout.lower())
    def test_audit_does_not_record_untrusted_text(self):
        with tempfile.TemporaryDirectory() as t:
            r=shell(f'AUDIT_FILE="{t}/operations.log"; audit_event "add https://secret" "bad/openflux://SECRET" fail')
            self.assertEqual(r.returncode,0,r.stderr)
            data=pathlib.Path(t,'operations.log').read_text()
            self.assertNotIn('SECRET',data); self.assertNotIn('https',data)
            self.assertEqual(pathlib.Path(t,'operations.log').stat().st_mode&0o777,0o600)
    def test_archive_rejects_traversal(self):
        with tempfile.TemporaryDirectory() as t:
            archive=pathlib.Path(t,'bad.tar')
            with tarfile.open(archive,'w') as tar:
                item=tarfile.TarInfo('../escape');item.size=1;tar.addfile(item,io.BytesIO(b'x'))
            r=shell(f'validate_archive "{archive}" "{t}/stage"')
            self.assertNotEqual(r.returncode,0)
            self.assertFalse(pathlib.Path(t,'escape').exists())
    def test_archive_rejects_symlink(self):
        with tempfile.TemporaryDirectory() as t:
            archive=pathlib.Path(t,'bad.tar')
            with tarfile.open(archive,'w') as tar:
                item=tarfile.TarInfo('conf/foo');item.type=tarfile.SYMTYPE;item.linkname='/etc';tar.addfile(item)
            r=shell(f'validate_archive "{archive}" "{t}/stage"')
            self.assertNotEqual(r.returncode,0)
            self.assertIn('архив',r.stderr.lower())
    def test_crypto_roundtrip_and_tamper(self):
        with tempfile.TemporaryDirectory() as t:
            p=pathlib.Path(t);(p/'plain').write_bytes(b'key data'*100)
            r=shell(f'crypto_archive encrypt "{p}/plain" "{p}/enc" 3<<<"strong-passphrase"; crypto_archive decrypt "{p}/enc" "{p}/out" 3<<<"strong-passphrase"')
            self.assertEqual(r.returncode,0,r.stderr);self.assertEqual((p/'out').read_bytes(),(p/'plain').read_bytes())
            blob=bytearray((p/'enc').read_bytes());blob[-40]^=1;(p/'enc').write_bytes(blob)
            r=shell(f'crypto_archive decrypt "{p}/enc" "{p}/bad" 3<<<"strong-passphrase"')
            self.assertNotEqual(r.returncode,0);self.assertFalse((p/'bad').exists())
    def test_crypto_wrong_password(self):
        with tempfile.TemporaryDirectory() as t:
            p=pathlib.Path(t);(p/'plain').write_bytes(b'private')
            r=shell(f'crypto_archive encrypt "{p}/plain" "{p}/enc" 3<<<"password-one"; crypto_archive decrypt "{p}/enc" "{p}/out" 3<<<"password-two"')
            self.assertNotEqual(r.returncode,0);self.assertFalse((p/'out').exists())
    def test_valid_archive_roundtrip_and_conflict(self):
        with tempfile.TemporaryDirectory() as t:
            p=pathlib.Path(t); base=p/'conf';state=p/'state';(base/'phone').mkdir(parents=True);(state/'phone').mkdir(parents=True)
            config='Role = exit\nMode = l4\nTransport = telemost\nURL = https://telemost.yandex.ru/j/12345\nEncryptionKeyFile = /etc/openflux-node/phone/encryption-key\nCookieStore = /var/lib/openflux-node/phone/cookies.json\n'
            (base/'phone/node.conf').write_text(config);(base/'phone/encryption-key').write_text('a'*64)
            r=shell(f'BASE="{base}"; STATE_ROOT="{state}"; pack_archive "{p}/archive"; validate_archive "{p}/archive" "{p}/stage"')
            self.assertEqual(r.returncode,0,r.stderr)
            self.assertEqual((p/'stage/conf/phone/node.conf').read_text(),config)
            r=shell(f'BASE="{base}"; STATE_ROOT="{state}"; validate_restore_targets "{p}/stage"')
            self.assertNotEqual(r.returncode,0)
            self.assertIn('занято',r.stderr)
    def test_bounded_restart_failure_is_reported(self):
        r=shell('UPDATE_UNITS=(fake.service); timeout() { return 124; }; systemctl() { return 1; }; sleep() { :; }; restart_update_units')
        self.assertNotEqual(r.returncode,0)
    def test_archive_rejects_extra_config_paths(self):
        with tempfile.TemporaryDirectory() as t:
            p=pathlib.Path(t);base=p/'conf';state=p/'state';(base/'phone').mkdir(parents=True);state.mkdir()
            (base/'phone/node.conf').write_text('Role = exit\nEncryptionKeyFile = /etc/shadow\nCookieStore = /tmp/anything\n')
            (base/'phone/encryption-key').write_text('a'*64)
            r=shell(f'BASE="{base}"; STATE_ROOT="{state}"; pack_archive "{p}/archive"; validate_archive "{p}/archive" "{p}/stage"')
            self.assertNotEqual(r.returncode,0)
            self.assertFalse((p/'stage').exists())
    def test_backup_failure_blocks_update_even_in_conditional(self):
        with tempfile.TemporaryDirectory() as t:
            r=shell(f"ask() {{ destination='{t}/archive'; }}; read_backup_password() {{ BACKUP_PASSWORD=example-password; }}; pack_archive() {{ return 9; }}; crypto_archive() {{ echo SHOULD_NOT_RUN; }}; backup_profiles || exit 42")
            self.assertEqual(r.returncode,42,r.stdout+r.stderr)
            self.assertNotIn('SHOULD_NOT_RUN',r.stdout)
            self.assertFalse(pathlib.Path(t,'archive').exists())
    def test_backup_temp_failure_never_attempts_plaintext_write(self):
        with tempfile.TemporaryDirectory() as t:
            r=shell(f"ask() {{ destination='{t}/archive'; }}; read_backup_password() {{ BACKUP_PASSWORD=example-password; }}; mktemp() {{ return 1; }}; pack_archive() {{ echo PLAINTEXT_WRITE; }}; backup_profiles || exit 42")
            self.assertEqual(r.returncode,42,r.stdout+r.stderr)
            self.assertNotIn('PLAINTEXT_WRITE',r.stdout)
    def test_archive_rejects_excessive_members(self):
        with tempfile.TemporaryDirectory() as t:
            archive=pathlib.Path(t,'many.tar.gz')
            with tarfile.open(archive,'w:gz') as tar:
                for i in range(10001):
                    item=tarfile.TarInfo(f'conf/phone/file{i}');tar.addfile(item,io.BytesIO())
            r=shell(f'validate_archive "{archive}" "{t}/stage"')
            self.assertNotEqual(r.returncode,0)
            self.assertIn('лимит',r.stderr)
    def test_script_download_validation(self):
        with tempfile.TemporaryDirectory() as t:
            p=pathlib.Path(t,'bad');p.write_text('<html>login</html>')
            r=shell(f'validate_installer "{p}"')
            self.assertNotEqual(r.returncode,0)
            self.assertIn('Bash',r.stderr)
if __name__=='__main__': unittest.main()
