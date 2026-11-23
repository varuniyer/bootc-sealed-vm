fetch_secret() { aws secretsmanager get-secret-value --secret-id "$1" --query SecretString --output text; }
