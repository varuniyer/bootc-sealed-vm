-- cat keeps the password off psql's argv.
\set password `cat`
CREATE ROLE experiments PASSWORD :'password';
SELECT rolpassword FROM pg_authid WHERE rolname='experiments';
