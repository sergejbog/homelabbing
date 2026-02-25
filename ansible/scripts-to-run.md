# Ansible Scripts

## Test container workflow

```shell
# 1. Start the test container (from ansible/test/)
cd ansible/test
docker compose up -d --build

# 2. Run the playbook against it
cd ..
ansible-playbook playbooks/setup.yml --limit test --ask-vault-pass

# 3. Verify manually
ssh -p 2222 root@localhost restic version
ssh -p 2222 root@localhost docker --version

# 4. Reset everything and run again
ansible-playbook playbooks/teardown.yml --limit test --ask-vault-pass
ansible-playbook playbooks/setup.yml --limit test --ask-vault-pass

# 5. Done — kill the container
cd test && docker compose down
```

## Run against production hosts

```shell
# Full setup on all hosts
ansible-playbook playbooks/setup.yml --ask-vault-pass

# Single host only
ansible-playbook playbooks/setup.yml --limit local --ask-vault-pass
ansible-playbook playbooks/setup.yml --limit ex44 --ask-vault-pass

# Teardown a host
ansible-playbook playbooks/teardown.yml --limit ex44 --ask-vault-pass
```

## Vault

```shell
# Encrypt secrets file
ansible-vault encrypt host_vars/secrets.yml

# Decrypt for editing
ansible-vault decrypt host_vars/secrets.yml

# Edit in place (never writes plaintext to disk)
ansible-vault edit host_vars/secrets.yml

# View without decrypting to disk
ansible-vault view host_vars/secrets.yml

# Re-key (change vault password)
ansible-vault rekey host_vars/secrets.yml

# Run playbook with vault password file instead of prompt
ansible-playbook playbooks/setup.yml --vault-password-file ~/.vault_pass
```

## Tags (run specific tasks only)

```shell
# Only deploy secrets/env files (vault-tagged tasks)
ansible-playbook playbooks/setup.yml --tags vault --ask-vault-pass

# Skip secrets, run everything else
ansible-playbook playbooks/setup.yml --skip-tags vault --ask-vault-pass
```

## Ad-hoc commands

```shell
# Ping all hosts
ansible all -m ping

# Check a variable value
ansible all -m debug -a "var=restic_version"

# Run a shell command on all hosts
ansible all -m shell -a "docker --version"

# Check disk usage on all hosts
ansible all -m shell -a "df -h /"

# Gather facts from a host
ansible local -m setup
```

## Dry run (check mode)

```shell
# See what would change without applying
ansible-playbook playbooks/setup.yml --check --ask-vault-pass

# Dry run with diff output
ansible-playbook playbooks/setup.yml --check --diff --ask-vault-pass
```
