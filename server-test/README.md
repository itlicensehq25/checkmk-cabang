# cmkagent Hybrid Push - test receiver

This receiver is only for validating the Android PUSH transport. It does **not** yet connect the push cache to Checkmk Community.

Run on the OMV host (example `192.168.55.112`):

```bash
mkdir -p /opt/cmkagent-test
cd /opt/cmkagent-test
python3 receiver.py --listen 0.0.0.0 --port 18080 --data-dir ./push-cache --token cmk-test-token
```

In cmkagent v1.3.0 settings:

- Enable PUSH backup: ON
- Push Receiver URL: `http://192.168.55.112:18080/api/v1/agent`
- Push Token: `cmk-test-token`
- Push Interval: `120`

Tap **TEST PUSH NOW**. A successful test should return HTTP 200 and create files such as:

```text
push-cache/PDA-TESTCOBA.agent
push-cache/PDA-TESTCOBA.json
```

Health test from another machine:

```bash
curl http://192.168.55.112:18080/health
```

For production, use HTTPS and a proper receiver service. The next server-side step is a Checkmk data source program that tries pull first and uses this cache only when pull fails.
