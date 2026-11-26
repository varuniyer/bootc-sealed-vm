\set postgresql_experiments_password_hash `cat`
CREATE ROLE experiments LOGIN PASSWORD :'postgresql_experiments_password_hash';
CREATE DATABASE experiments OWNER experiments;
REVOKE CONNECT, TEMPORARY ON DATABASE postgres, template1, experiments FROM PUBLIC;
