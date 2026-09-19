-- The mangos user itself is created from MARIADB_USER before this runs.
CREATE DATABASE IF NOT EXISTS realmd DEFAULT CHARSET utf8 COLLATE utf8_general_ci;
CREATE DATABASE IF NOT EXISTS characters DEFAULT CHARSET utf8 COLLATE utf8_general_ci;
CREATE DATABASE IF NOT EXISTS mangos DEFAULT CHARSET utf8 COLLATE utf8_general_ci;
CREATE DATABASE IF NOT EXISTS logs DEFAULT CHARSET utf8 COLLATE utf8_general_ci;
GRANT ALL ON realmd.* TO 'mangos'@'%';
GRANT ALL ON characters.* TO 'mangos'@'%';
GRANT ALL ON mangos.* TO 'mangos'@'%';
GRANT ALL ON logs.* TO 'mangos'@'%';
