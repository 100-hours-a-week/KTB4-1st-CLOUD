"""AWS에 접속하지 않고 로컬 편집·반영과 비밀값 처리를 검증한다."""
import argparse
import contextlib
import importlib.util
import io
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('ssm_env', Path(__file__).with_name('ssm-env.py'))
ssm = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ssm)


class SsmEnvTest(unittest.TestCase):
    def setUp(self):
        self.folder = tempfile.TemporaryDirectory()
        self.addCleanup(self.folder.cleanup)
        self.path = Path(self.folder.name) / '.env.staging.be'
        self.context = {'account': '123456789012', 'region': 'ap-northeast-2', 'path': '/bakkucca-v2-staging/be/'}
        self.items = {
            'JWT_SECRET': {'Name': self.context['path'] + 'JWT_SECRET', 'Type': 'SecureString',
                           'KeyId': 'alias/custom', 'Version': 4, 'Value': 'old-private-value', 'readonly': False},
            'CLOUDFRONT_PRIVATE_KEY_PEM': {'Name': self.context['path'] + 'CLOUDFRONT_PRIVATE_KEY_PEM',
                'Type': 'SecureString', 'Version': 1, 'Value': '-----BEGIN-----\n$secret="x"\n-----END-----\n', 'readonly': False},
            'DB_URL': {'Name': self.context['path'] + 'DB_URL', 'Type': 'String', 'Version': 2,
                       'Value': 'jdbc:mysql://example/market', 'readonly': True},
        }
        with contextlib.redirect_stdout(io.StringIO()):
            ssm.pull(argparse.Namespace(force=False), self.path, self.context, self.items)

    def test_roundtrip_pem_and_permissions(self):
        _, context, values, versions = ssm.read_env(self.path)
        self.assertEqual(context, self.context)
        self.assertEqual(values['CLOUDFRONT_PRIVATE_KEY_PEM'], self.items['CLOUDFRONT_PRIVATE_KEY_PEM']['Value'])
        self.assertNotIn('DB_URL', values)
        self.assertEqual(versions['JWT_SECRET'], 4)
        self.assertEqual(self.path.stat().st_mode & 0o777, 0o600)

    def test_changed_only_and_missing_key_not_deleted(self):
        updates = ssm.changes(self.items, {'JWT_SECRET': 'new'}, {'JWT_SECRET': 4})
        self.assertEqual([key for key, _, _ in updates], ['JWT_SECRET'])
        self.assertEqual(ssm.changes(self.items, {'JWT_SECRET': 'old-private-value'}, {}), [])

    def test_stale_readonly_new_and_empty_values_rejected(self):
        for values, versions in [({'JWT_SECRET': 'new'}, {'JWT_SECRET': 3}),
                                 ({'DB_URL': 'other'}, {'DB_URL': 2}),
                                 ({'NEW_SECRET': 'new'}, {}),
                                 ({'JWT_SECRET': ''}, {'JWT_SECRET': 4})]:
            with self.subTest(values=list(values)):
                with self.assertRaises(ssm.EnvError):
                    ssm.changes(self.items, values, versions)

    def test_duplicate_or_unclosed_value_rejected(self):
        original = self.path.read_text()
        for suffix in ['JWT_SECRET="duplicate"\n', 'BROKEN="unclosed\n']:
            self.path.write_text(original + suffix)
            with self.assertRaises(ssm.EnvError):
                ssm.read_env(self.path)

    def test_push_keeps_type_key_and_updates_version_without_logging_value(self):
        self.path.write_text(self.path.read_text().replace('old-private-value', 'new-private-value'))
        output = io.StringIO()
        calls = []
        def fake_aws(args, service, operation, payload=None):
            calls.append((operation, payload))
            return {'Account': self.context['account']} if operation == 'get-caller-identity' else {'Version': 5}
        with patch.object(ssm, 'inventory', return_value=(self.context['path'], self.items)), \
             patch.object(ssm, 'aws', side_effect=fake_aws), \
             patch('sys.argv', ['ssm-env.py', 'push', 'staging', 'be', '--file', str(self.path)]), \
             contextlib.redirect_stdout(output):
            ssm.main()
        payload = next(p for op, p in calls if op == 'put-parameter')
        self.assertEqual(payload['Type'], 'SecureString')
        self.assertEqual(payload['KeyId'], 'alias/custom')
        self.assertNotIn('new-private-value', output.getvalue())
        self.assertEqual(ssm.read_env(self.path)[3]['JWT_SECRET'], 5)

    def test_dry_run_does_not_write(self):
        self.path.write_text(self.path.read_text().replace('old-private-value', 'new'))
        with patch.object(ssm, 'inventory', return_value=(self.context['path'], self.items)), \
             patch.object(ssm, 'aws', return_value={'Account': self.context['account']}) as aws, \
             patch('sys.argv', ['ssm-env.py', 'push', 'staging', 'be', '--file', str(self.path), '--dry-run']), \
             contextlib.redirect_stdout(io.StringIO()):
            ssm.main()
        self.assertEqual(aws.call_count, 1)

    def test_wrong_account_rejected_before_fetch_or_write(self):
        with patch.object(ssm, 'inventory') as inventory, \
             patch.object(ssm, 'aws', return_value={'Account': 'different-account'}), \
             patch('sys.argv', ['ssm-env.py', 'push', 'staging', 'be', '--file', str(self.path)]):
            with self.assertRaises(ssm.EnvError):
                ssm.main()
        inventory.assert_not_called()

    def test_aws_values_use_private_temporary_file_and_cleanup(self):
        args = argparse.Namespace(region='ap-northeast-2', profile=None)
        payload = {'Name': '/test', 'Value': 'private-argv-check'}
        requests = []
        def inspect_request(command, **kwargs):
            self.assertNotIn('private-argv-check', ' '.join(command))
            path = Path(command[command.index('--cli-input-json') + 1].removeprefix('file://'))
            requests.append(path)
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)
            self.assertEqual(json.loads(path.read_text()), payload)
            return subprocess.CompletedProcess(command, 0, '{"Version": 2}', '')
        with patch.object(ssm.subprocess, 'run', side_effect=inspect_request):
            ssm.aws(args, 'ssm', 'put-parameter', payload)
        self.assertFalse(requests[0].exists())

    def test_aws_error_also_removes_temporary_file(self):
        args = argparse.Namespace(region='ap-northeast-2', profile=None)
        requests = []
        def failure(command, **kwargs):
            requests.append(Path(command[-1].removeprefix('file://')))
            return subprocess.CompletedProcess(command, 1, '', '(AccessDeniedException) private-error-value')
        with patch.object(ssm.subprocess, 'run', side_effect=failure):
            with self.assertRaises(ssm.EnvError) as error:
                ssm.aws(args, 'ssm', 'put-parameter', {'Value': 'private-error-value'})
        self.assertNotIn('private-error-value', str(error.exception))
        self.assertFalse(requests[0].exists())

    @unittest.skipUnless(shutil.which('aws'), 'AWS CLI가 설치돼 있지 않음')
    def test_actual_cli_describe_request_offline(self):
        """실제 CLI가 요청 파일을 읽는지 확인한다. 네트워크·실제 자격증명은 사용하지 않는다."""
        args = argparse.Namespace(region='ap-northeast-2', profile=None)
        original_run = subprocess.run
        def offline(command, **kwargs):
            kwargs['env'] = {**kwargs['env'], 'AWS_ACCESS_KEY_ID': 'offline-validation',
                             'AWS_SECRET_ACCESS_KEY': 'offline-validation', 'AWS_SESSION_TOKEN': '',
                             'AWS_EC2_METADATA_DISABLED': 'true'}
            return original_run(command + ['--generate-cli-skeleton', 'output'], **kwargs)
        with patch.object(ssm.subprocess, 'run', side_effect=offline):
            for filters in [
                [{'Key': 'Path', 'Option': 'Recursive', 'Values': ['/bakkucca-v2-staging/be']}],
                [{'Key': 'Path', 'Option': 'Recursive', 'Values': ['/bakkucca-v2-staging/be']},
                 {'Key': 'tag:ManagedBy', 'Values': ['terraform']}],
            ]:
                self.assertIn('Parameters', ssm.aws(args, 'ssm', 'describe-parameters', {'ParameterFilters': filters}))


if __name__ == '__main__':
    unittest.main()
