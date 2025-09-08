BEGIN TRANSACTION;
CREATE TABLE IF NOT EXISTS "genesis" (
	"entry_id"	INTEGER,
	"title"	TEXT NOT NULL,
	"entry_text"	TEXT NOT NULL,
	PRIMARY KEY("entry_id")
);
INSERT INTO "genesis" VALUES (1,'Genesis 1:1','In the beginning God created the heaven and the earth.');
INSERT INTO "genesis" VALUES (2,'Genesis 1:2','And the earth was without form, and void; and darkness was upon the face of the deep.');
INSERT INTO "genesis" VALUES (3,'Genesis 1:3','And God said, Let there be light: and there was light.');
INSERT INTO "genesis" VALUES (4,'Genesis 2:1','Thus the heavens and the earth were finished, and all the host of them.');
INSERT INTO "genesis" VALUES (5,'Genesis 2:2','And on the seventh day God ended his work which he had made; and he rested on the seventh day from all his work which he had made.');
COMMIT;
