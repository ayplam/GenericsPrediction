/*------------------------------------------------
			INITIALIZATION
-------------------------------------------------*/

\echo '\n************************************************'
\echo '*      Initializing... creating all tables     *'
\echo '************************************************\n' 
-- NDCDB never used.
DROP TABLE IF EXISTS ndcdb;
CREATE TABLE ndcdb ( productid varchar(50),
	productndc varchar(12),
	ndcpackagecode varchar(15),
	packagedesc varchar(512));
	
\copy ndcdb FROM 'package.txt'  CSV HEADER DELIMITER E'\t';

DROP TABLE IF EXISTS ndcdir;
CREATE TABLE ndcdir ( prodid VARCHAR(47), prodndc varchar(10), prodtypename varchar(32), 
	proprietaryname varchar(256), proprietarynamesuffix varchar(128), nonproprietaryname varchar(512), 
	dosageform varchar(64), routename varchar(128), startmktdate date, endmktdate date, 
	mktcategoryname varchar(64), appnum varchar(11), supplier varchar(120), substancename varchar(4096),
	activenumstr varchar(1024), activeingredunit varchar(4096),  
	pharmclass varchar(4096), deaschedule varchar(4), epc varchar(1024), moa varchar(424) );
	
\copy ndcdir FROM 'product_parsed.csv' WITH NULL AS 'NULL' DELIMITER ',';
UPDATE ndcdir SET nonproprietaryname=TRIM( nonproprietaryname );
UPDATE ndcdir SET proprietaryname=TRIM( proprietaryname );

-- New table from: http://www.fda.gov/downloads/Drugs/DevelopmentApprovalProcess/UCM071436.pdf
-- Shows all bioequivalence
-- Needs parsing. 
DROP TABLE IF EXISTS fdandapairs;
CREATE TABLE fdandapairs ( appnum varchar(10), drug varchar(128));
\copy fdandapairs FROM 'df_ndapairs.csv' CSV DELIMITER ',';

/* This table has a lot of pharmacokinetics/dynamics information.
-- OTC drugs since 2009
-- RX drugs since 2006
-- Currently not using this data. Takes too long to join.	
DROP TABLE IF EXISTS dailymed;
CREATE TABLE dailymed ( zipfile varchar(50), xmlfile varchar(41), rxtype varchar(3), origzip varchar(62) );
\copy dailymed FROM 'dailymed.csv' WITH CSV HEADER DELIMITER ','; */

/* ------------------------------------------------------------ 
These are some useful tables to cut down on processing time. 

-- There are essentially 2375 unique nonproprietary names, though there are multiple forms of each one 
(4085 when including unique dosage forms, 
8563 if you're only counting unique application numbers)

-------------------------------------------------------------*/

DROP TABLE IF EXISTS fdadrugs;
DROP TABLE IF EXISTS ndadrugs;
DROP TABLE IF EXISTS ndaauthgendrugs;
DROP TABLE IF EXISTS andadrugs;

CREATE TABLE fdadrugs AS
SELECT DISTINCT ON(prodndc) * FROM ndcdir WHERE (mktcategoryname IN ('ANDA', 'NDA', 'NDA AUTHORIZED GENERIC')) ORDER BY prodndc, startmktdate;

CREATE TABLE ndadrugs AS
SELECT DISTINCT ON(prodndc) * FROM ndcdir WHERE (mktcategoryname IN ('NDA'))  ORDER BY prodndc, startmktdate;

CREATE TABLE ndaauthgendrugs AS
SELECT DISTINCT ON(prodndc) * FROM ndcdir WHERE (mktcategoryname IN ('NDA', 'NDA AUTHORIZED GENERIC'))  ORDER BY prodndc, startmktdate;

CREATE TABLE andadrugs AS
SELECT DISTINCT ON(prodndc) * FROM ndcdir WHERE (mktcategoryname LIKE 'ANDA' )  ORDER BY prodndc, startmktdate;


/*------------------------------------------------
Summary: Use the bioequivalence PDF to match up 
all the brand/gx pairs to find out the time it takes 
for brand to generic conversion.
-------------------------------------------------*/

\echo '\n************************************************';
\echo '*   Joining FDA brand and generic equivalents    *';
\echo '************************************************\n';

--This table matches up the bx to gx equivalents from the PDF provided by the FDA which shows bioequivalence.
--The drugs were matched up from the PDF based on their NDA/ANDA application number.
DROP TABLE IF EXISTS bxgxmatch_fda;	
CREATE TABLE bxgxmatch_fda AS
SELECT * FROM
( SELECT fdadrugs.*, fdandapairs.drug FROM
fdandapairs
INNER JOIN
fdadrugs
ON fdadrugs.appnum LIKE fdandapairs.appnum ) AS drugmatch
ORDER BY drug,startmktdate;

-- Don't actually use this....I don't think. But I can!
\copy bxgxmatch_fda TO 'bxgxmatch_fda.csv' WITH CSV HEADER DELIMITER AS ',';

-- This table uses the FDA bioequivalence PDF. It finds the FIRST instance of an NDA and pairs it up with the FIRST instance of an ANDA. This will 
-- be the conversion time from brand -> gx
DROP TABLE IF EXISTS bxgxdiff_fda;
CREATE TABLE bxgxdiff_fda AS
SELECT *, gxdate - bxdate AS bxgxtime FROM 
	(SELECT DISTINCT ON (drug) SUBSTRING(UPPER(prodid),'.{36}$') AS gxprodid, startmktdate AS gxdate, nonproprietaryname AS gxname, drug, epc, dosageform, routename FROM bxgxmatch_fda WHERE appnum LIKE 'ANDA%') AS firstanda
	INNER JOIN
	(SELECT DISTINCT ON (drug) SUBSTRING(UPPER(prodid),'.{36}$') AS bxprodid, startmktdate AS bxdate, proprietaryname AS bxname, drug AS ndadrug FROM bxgxmatch_fda WHERE appnum LIKE 'NDA%') AS firstnda
ON firstanda.drug LIKE firstnda.ndadrug;
ALTER TABLE bxgxdiff_fda DROP COLUMN ndadrug;
-- And in the above table, I still get a bunch of "The bxdate is before the gxdate"

-- The minimum exclusivity is 180 days. Kick out anything that doesn't match that.
\copy (SELECT * FROM bxgxdiff_fda WHERE bxgxtime > 180) TO 'firstbxgxmatch_fdalist.csv' WITH CSV HEADER DELIMITER AS ',';

/*------------------------------------------------
Summary: Model the time series of how generics are 
released. Is there any pattern as to seasonality or
timing for when a larger number of drugs are released?
-------------------------------------------------*/

\echo '\n************************************************'
\echo '* Creating a table to show seasonality patterns *'
\echo '************************************************\n'

-- Select only suppliers who have submitted at least 50 ANDAs to filter out some "noise" of the smaller suppliers
-- Only select from dates > 2000 for more recent items.
DROP TABLE IF EXISTS tmp;
CREATE TABLE tmp AS
SELECT andadrugs.* FROM
(SELECT supplier, COUNT(supplier) FROM andadrugs WHERE startmktdate > date '2000-01-01' GROUP BY supplier HAVING COUNT(supplier) > 50) AS majorsupplier
LEFT JOIN
andadrugs
ON (majorsupplier.supplier LIKE andadrugs.supplier)
ORDER BY nonproprietaryname, startmktdate, supplier;

\copy tmp TO 'major_supplier_release_dates.csv' WITH CSV HEADER DELIMITER AS ',';
DROP TABLE tmp;

/*------------------------------------------------
Summary: Model number of suppliers for a given gxname drug

Features
-# of corresponding bx drug listings
-# Date of bx drug 	

To predict
-# of suppliers during release
-# of suppliers 1 year after release
-# of suppliers 3 years after release

Results: Nothing good.
-------------------------------------------------*/

\echo '\n************************************************'
\echo '*   Attempt to model # of suppliers in market  *'
\echo '************************************************\n'


-- bxFeatures0 essentially has number of suppliers for any given date and the number of releases.
-- They all happen BEFORE the first ANDA release.
DROP TABLE IF EXISTS bxFeatures0;
CREATE TABLE bxFeatures0 AS
SELECT nSuppliersAndReleases.*, BxGxDifference.bxgxdiff FROM
( SELECT DISTINCT ON (ndaauthdrugs.nonproprietaryname, ndaauthdrugs.dosageform) ndaauthdrugs.nonproprietaryname, ndaauthdrugs.dosageform, ndaauthdrugs.startmktdate, (andastartmktdate.startmktdate - ndaauthdrugs.startmktdate) AS bxgxdiff FROM 
ndaauthdrugs
INNER JOIN 
( SELECT DISTINCT ON (nonproprietaryname, dosageform) nonproprietaryname, dosageform, startmktdate FROM andadrugs WHERE startmktdate > date '1995-01-01' ORDER BY nonproprietaryname, dosageform, startmktdate ) AS andastartmktdate
ON ( andastartmktdate.nonproprietaryname LIKE ndaauthdrugs.nonproprietaryname 
AND andastartmktdate.dosageform LIKE ndaauthdrugs.dosageform 
AND andastartmktdate.startmktdate > ndaauthdrugs.startmktdate  )
ORDER BY ndaauthdrugs.nonproprietaryname, ndaauthdrugs.dosageform, ndaauthdrugs.startmktdate ) AS BxGxDifference   -- This table shows the brand to generic time conversion
INNER JOIN
( SELECT ndaauthdrugs.nonproprietaryname, ndaauthdrugs.dosageform, COUNT(DISTINCT(ndaauthdrugs.supplier)) AS nsuppliers, COUNT(ndaauthdrugs.nonproprietaryname) AS nreleases, ndaauthdrugs.startmktdate FROM 
ndaauthdrugs
INNER JOIN 
( SELECT DISTINCT ON (nonproprietaryname, dosageform) nonproprietaryname, dosageform, startmktdate FROM andadrugs WHERE startmktdate > date '1995-01-01' ORDER BY nonproprietaryname, dosageform, startmktdate ) AS andastartmktdate
ON ( andastartmktdate.nonproprietaryname LIKE ndaauthdrugs.nonproprietaryname 
AND andastartmktdate.dosageform LIKE ndaauthdrugs.dosageform 
AND andastartmktdate.startmktdate > ndaauthdrugs.startmktdate  )
GROUP BY ndaauthdrugs.nonproprietaryname, ndaauthdrugs.dosageform, ndaauthdrugs.startmktdate
ORDER BY ndaauthdrugs.nonproprietaryname, ndaauthdrugs.dosageform, ndaauthdrugs.startmktdate ) AS nSuppliersAndReleases -- This table shows the number of suppliers and releases
ON ( BxGxDifference.nonproprietaryname LIKE nSuppliersAndReleases.nonproprietaryname 
AND BxGxDifference.dosageform LIKE nSuppliersAndReleases.dosageform );

-- This is the TOTAL number of suppliers/releases before the first ANDA drug is released.
-- TABLE A
/*
SELECT totSuppliersAndReleases.*, firstmktdate, bxgxdiff FROM
( SELECT DISTINCT ON(nonproprietaryname, dosageform) nonproprietaryname, dosageform, startmktdate AS firstmktdate, bxgxdiff FROM 
bxFeatures0
ORDER BY nonproprietaryname, dosageform, startmktdate ) AS ndaReleaseDate
INNER JOIN
( SELECT nonproprietaryname, dosageform, SUM(nsuppliers) AS totsuppliers, SUM(nreleases) AS totreleases FROM
bxFeatures0
GROUP BY nonproprietaryname, dosageform ) AS totSuppliersAndReleases
ON ( ndaReleaseDate.nonproprietaryname LIKE totSuppliersAndReleases.nonproprietaryname 
AND ndaReleaseDate.dosageform LIKE totSuppliersAndReleases.dosageform ); */

-- nSuppliers is what you want to model
-- Not sure if nReleases with X period will be useful, but it's there.
-- Can change INTERVAL to change the prediction of "How many suppliers will be in the market after N years"
-- TABLE B

/* 
SELECT andadrugs.nonproprietaryname, andadrugs.dosageform, COUNT(DISTINCT(andadrugs.supplier)) as nsuppliers, COUNT(andadrugs.nonproprietaryname) AS nreleases FROM 
( SELECT DISTINCT ON (nonproprietaryname, dosageform) nonproprietaryname, dosageform, startmktdate FROM andadrugs WHERE startmktdate > date '1990-01-01'  AND startmktdate < '2012-06-06' ORDER BY nonproprietaryname, dosageform, startmktdate ) AS andastartmktdate
INNER JOIN
andadrugs 
ON andastartmktdate.nonproprietaryname LIKE andadrugs.nonproprietaryname 
AND andastartmktdate.dosageform LIKE andadrugs.dosageform 
AND andastartmktdate.startmktdate + INTERVAL '3 years' >= andadrugs.startmktdate
WHERE andadrugs.startmktdate < date '2012-01-01'
GROUP BY andadrugs.nonproprietaryname, andadrugs.dosageform ORDER BY nonproprietaryname ; */

-- Join TABLE A and B
DROP TABLE IF EXISTS tmp;
CREATE TABLE tmp AS (
SELECT Xfeatures.*, YModel.nsuppliers, YModel.nreleases FROM
( SELECT totSuppliersAndReleases.*, firstmktdate, bxgxdiff FROM
( SELECT DISTINCT ON(nonproprietaryname, dosageform) nonproprietaryname, dosageform, startmktdate AS firstmktdate, bxgxdiff FROM 
bxFeatures0
ORDER BY nonproprietaryname, dosageform, startmktdate ) AS ndaReleaseDate
INNER JOIN
( SELECT nonproprietaryname, dosageform, SUM(nsuppliers) AS totsuppliers, SUM(nreleases) AS totreleases FROM
bxFeatures0
GROUP BY nonproprietaryname, dosageform ) AS totSuppliersAndReleases
ON ( ndaReleaseDate.nonproprietaryname LIKE totSuppliersAndReleases.nonproprietaryname 
AND ndaReleaseDate.dosageform LIKE totSuppliersAndReleases.dosageform ) ) AS Xfeatures
INNER JOIN
( SELECT andadrugs.nonproprietaryname, andadrugs.dosageform, COUNT(DISTINCT(andadrugs.supplier)) as nsuppliers, COUNT(andadrugs.nonproprietaryname) AS nreleases FROM 
( SELECT DISTINCT ON (nonproprietaryname, dosageform) nonproprietaryname, dosageform, startmktdate FROM andadrugs WHERE startmktdate > date '1990-01-01'  AND startmktdate < '2012-06-06' ORDER BY nonproprietaryname, dosageform, startmktdate ) AS andastartmktdate
INNER JOIN
andadrugs 
ON andastartmktdate.nonproprietaryname LIKE andadrugs.nonproprietaryname 
AND andastartmktdate.dosageform LIKE andadrugs.dosageform 
AND andastartmktdate.startmktdate + INTERVAL '3 years' >= andadrugs.startmktdate
WHERE andadrugs.startmktdate < date '2012-01-01'
GROUP BY andadrugs.nonproprietaryname, andadrugs.dosageform ORDER BY nonproprietaryname ) AS YModel
ON ( Xfeatures.nonproprietaryname LIKE YModel.nonproprietaryname 
AND Xfeatures.dosageform LIKE YModel.dosageform )
WHERE bxgxdiff > 150 ); -- Must be minimum 150 days in between bxgxdiff to count. Otherwise it likely wasn't a "TRUE" conversion

\copy tmp  TO 'supplier_model.csv' WITH CSV HEADER DELIMITER AS ',';
DROP TABLE tmp;

/*------------------------------------------------
Summary: Model individual suppliers to see whether or not they have seasonality in releases.

Filters:
-# of suppliers with > 50 releases after 2005

-Results: Nothing really...yet.

-------------------------------------------------*/
CREATE TABLE tmp AS
SELECT after05.* FROM 
( SELECT * FROM andadrugs WHERE startmktdate > date '2005-01-01' ) AS after05
INNER JOIN
( SELECT supplier, count(supplier) FROM andadrugs WHERE startmktdate > date '2005-01-01' GROUP BY supplier HAVING count(supplier) > 50 ) AS majorsupplier
ON after05.supplier LIKE majorsupplier.supplier 
ORDER BY after05.supplier, after05.startmktdate;

\copy tmp TO 'major_suppliers_after05.csv' WITH CSV HEADER DELIMITER AS ',';
DROP TABLE tmp;


/*------------------------------------------------
Summary: Drug history for visualization of # of
NDAs and ANDAs that were submitted over time.

For: Visualization of ANDA/NDAs over time
-------------------------------------------------*/

\echo '\n************************************************'
\echo '* Visualizing releases of ANDA and NDA over time  *'
\echo '************************************************\n'

-- Total regardless of same ANDA/NDA or not. 
DROP TABLE IF EXISTS drugcounthistory;
CREATE TABLE drugcounthistory AS
SELECT andadrugcount.*, ndadrugcount.* FROM
(SELECT startmktdate AS andastt, COUNT(startmktdate) AS andacount FROM andadrugs WHERE startmktdate > date '1990-01-01' GROUP BY startmktdate ORDER BY startmktdate) AS andadrugcount
FULL JOIN 
(SELECT startmktdate AS ndastt, COUNT(startmktdate) AS ndacount FROM ndadrugs WHERE startmktdate > date '1990-01-01' GROUP BY startmktdate ORDER BY startmktdate) AS ndadrugcount
ON andadrugcount.andastt = ndadrugcount.ndastt;
UPDATE drugcounthistory SET andacount=0 WHERE andacount IS NULL;
UPDATE drugcounthistory SET andastt=ndastt WHERE andastt IS NULL;
UPDATE drugcounthistory SET ndacount=0 WHERE ndacount IS NULL;
UPDATE drugcounthistory SET ndastt=andastt WHERE ndastt IS NULL;
\copy (SELECT * FROM drugcounthistory ORDER BY andastt) TO 'drugcounthistory.csv' WITH CSV HEADER DELIMITER AS ',';

-- This is now UNIQUE ANDAs as determined by appnum
DROP TABLE IF EXISTS drugcounthistory;
CREATE TABLE drugcounthistory AS
SELECT andadrugcount.*, ndadrugcount.* FROM
( SELECT andastt, count(andastt) AS andacount FROM (SELECT DISTINCT ON(appnum) startmktdate AS andastt FROM andadrugs ORDER BY appnum, startmktdate) AS andadrugcount GROUP BY andastt ORDER BY andastt ) AS andadrugcount
FULL JOIN
( SELECT ndastt, count(ndastt) AS ndacount FROM (SELECT DISTINCT ON(appnum) startmktdate AS ndastt FROM ndadrugs ORDER BY appnum, startmktdate) AS ndadrugcount GROUP BY ndastt ORDER BY ndastt ) AS ndadrugcount
ON andadrugcount.andastt = ndadrugcount.ndastt;

/*------------------------------------------------
Summary: How many drugs (total) are released on any particular date of each month?
-------------------------------------------------*/
CREATE TABLE tmp AS
SELECT DAY, COUNT(DAY), CAST( COUNT(DAY) AS FLOAT) * 100 / ( SELECT COUNT(*) 	FROM andadrugs WHERE startmktdate >= date '2005-01-01' ) AS percent FROM
( SELECT *, CAST(EXTRACT(DAY FROM startmktdate) AS INT) as DAY FROM andadrugs WHERE startmktdate >= date '2005-01-01') AS andadrugs2
GROUP BY day ORDER BY day;

\copy tmp TO 'average_releases_days_2005toCurrent.csv' WITH CSV HEADER DELIMITER AS ',';
DROP TABLE tmp;

/*------------------------------------------------
Summary: How many drugs (total) are released on any particular day of each week?
-------------------------------------------------*/

\echo '\n********************************************'
\echo '*       FDA Drug Releases Day of Week      *';
\echo '********************************************\n'
SELECT dayofweek, count(dayofweek) FROM 
( SELECT EXTRACT(DOW FROM startmktdate) AS dayofweek, startmktdate FROM andadrugs WHERE startmktdate >= date '2005-01-01') AS weekday
GROUP BY dayofweek ORDER BY dayofweek;

/*-----------------
 ANDA DRUGS > 2005
 dayofweek | count
-----------+-------
         0 |   528
         1 |  5440
         2 |  4920
         3 |  5091
         4 |  4341
         5 |  4067
         6 |   804
----------------*/

/*------------------------------------------------

Summary: Do any suppliers have similar monthly 
releases to each other?

-Only consider larger suppliers
-Sort by monthly to matrix factorize
-Split by each year. Only do last 3 years (since you have full years)

-------------------------------------------------*/

\echo '\n********************************************'
\echo '*    Showing supplier monthly releases     *'
\echo '********************************************\n'

CREATE TABLE tmp AS
SELECT after11.supplier, yr, mo, COUNT(after11.supplier) FROM
( SELECT supplier, startmktdate, EXTRACT(MONTH FROM startmktdate) AS mo, EXTRACT(YEAR FROM startmktdate) AS yr FROM andadrugs WHERE startmktdate >= date'2011-01-01' AND startmktdate <= date'2014-12-31' ) AS after11
INNER JOIN
( SELECT supplier, count(supplier) FROM andadrugs WHERE startmktdate > date '2011-01-01' GROUP BY supplier HAVING count(supplier) > 50 ) AS majorsupplier
ON (after11.supplier = majorsupplier.supplier)
GROUP BY after11.supplier,yr,mo 
ORDER BY after11.supplier,yr,mo;

\copy tmp TO 'monthly_releases_2011to2014.csv' WITH CSV HEADER DELIMITER AS ',';
DROP TABLE tmp;

-- Unused SQL Queries:

/*------------------------------------------------
-- Probably ~90% of the time, there is SOMETHING released on the first of each month.
-- Is ANYTHING released?
SELECT yr,dy,count(yr) FROM 
( SELECT DISTINCT ON (startmktdate) EXTRACT(day FROM startmktdate) AS dy, EXTRACT(month FROM startmktdate) AS mo, EXTRACT(year FROM startmktdate) AS yr FROM ndadrugs WHERE startmktdate >= date '2005-01-01' ORDER BY startmktdate) AS dyreleased
GROUP BY yr,dy ORDER BY yr,dy;

-- vs 
-- The VOLUME of things released
SELECT yr,dy,count(yr) FROM 
( SELECT EXTRACT(day FROM startmktdate) AS dy, EXTRACT(month FROM startmktdate) AS mo, EXTRACT(year FROM startmktdate) AS yr FROM ndadrugs WHERE startmktdate >= date '2005-01-01' ORDER BY startmktdate) AS dyreleased
GROUP BY yr,dy ORDER BY yr,dy;

SELECT dy, avg(cnt) FROM
( SELECT yr,dy,count(yr) AS cnt FROM 
( SELECT DISTINCT ON (startmktdate) EXTRACT(day FROM startmktdate) AS dy, EXTRACT(month FROM startmktdate) AS mo, EXTRACT(year FROM startmktdate) AS yr FROM ndadrugs WHERE startmktdate >= date '2005-01-01' ORDER BY startmktdate) AS dyreleased
GROUP BY yr,dy ORDER BY yr,dy ) AS tmp
GROUP BY dy ORDER BY dy;


SELECT yr,dy, count(dy) AS cnt FROM 
( SELECT EXTRACT(day FROM startmktdate) AS dy, EXTRACT(year FROM startmktdate) AS yr FROM andadrugs WHERE startmktdate >= date '2005-01-01') AS dyreleased
GROUP BY yr,dy ORDER BY cnt DESC;

-------------------------------------------------*/


/*------------------------------------------------
Summary: What kinds of drugs are released on Jan 1st/July 1st?
-- Number of releases for dates 1/1 and 7/1 
SELECT startmktdate, count(startmktdate) FROM andadrugs 
WHERE EXTRACT(DAY FROM startmktdate) =1 AND EXTRACT(MONTH FROM startmktdate) IN (1,7) AND EXTRACT(YEAR FROM startmktdate) >= 2009 
GROUP BY startmktdate
ORDER BY startmktdate;

-- What percent are drugs in which they were released for the FIRST TIME?
-- 27 have matches - they were released for the FIRST TIME. (24 products if you don't include dosageform as a matching factor.)
-- The majority of these 27 was in 2014
-- In total, there are 276 products.
-- So less than 10% are never before released products.

SELECT COUNT(*) FROM
( SELECT janjul1_releases.* FROM
( SELECT DISTINCT ON(nonproprietaryname) * FROM andadrugs 
WHERE EXTRACT(DAY FROM startmktdate) =1 AND EXTRACT(MONTH FROM startmktdate) IN (1,7) AND EXTRACT(YEAR FROM startmktdate) >= 2009 
ORDER BY nonproprietaryname, dosageform, startmktdate ) janjul1_releases
INNER JOIN
( SELECT DISTINCT ON(nonproprietaryname) * FROM andadrugs 
ORDER BY nonproprietaryname, dosageform, startmktdate ) firstanda
ON (janjul1_releases.nonproprietaryname LIKE firstanda.nonproprietaryname AND janjul1_releases.startmktdate=firstanda.startmktdate) ) AS tmp;

--Which companies participate in this Jan/Jul1st release?
SELECT supplier, count(supplier), startmktdate FROM andadrugs 
WHERE EXTRACT(DAY FROM startmktdate) =1 AND EXTRACT(MONTH FROM startmktdate) IN (1,7) AND EXTRACT(YEAR FROM startmktdate) >= 2009 
GROUP BY supplier, startmktdate ORDER BY supplier;

-------------------------------------------------*/

/*------------------------------------------------
Summary: Matching up the XML zip files to the fdadrugs
table

Results: XML tables are too big, would take too long to join.

DROP TABLE IF EXISTS fda_dm_match;
CREATE TABLE fda_dm_match AS
SELECT fdadrugs.*, dailymed.* FROM 
(SELECT SUBSTRING(UPPER(prodid),'.{36}$') as sprodid, fdadrugs.* FROM fdadrugs) AS fdadrugs
RIGHT JOIN
(SELECT SUBSTRING(UPPER(xmlfile),'[A-Z0-9-]{36}') as s2prodid, dailymed.* FROM dailymed LIMIT 10) AS dailymed
ON (fdadrugs.sprodid LIKE dailymed.s2prodid);
SELECT SUBSTRING(UPPER(prodid),'.{36}$') as sprodid, fdadrugs.* FROM fdadrugs


SELECT DISTINCT ON(prodid2) * FROM (SELECT SUBSTRING(UPPER(prodid),'.{36}$') AS prodid2, * FROM fdadrugs
ORDER BY prodid2, startmktdate;

CREATE TABLE fdadrugs_idx AS
SELECT SUBSTRING(UPPER(prodid),'.{36}$') AS prodid2, * FROM fdadrugs;

CREATE INDEX idx_prodid ON fdadrugs_idx(prodid2);

CREATE TABLE dailymed_idx AS
SELECT SUBSTRING(UPPER(xmlfile),'[A-Z0-9-]{36}') as zipid2, dailymed.* FROM dailymed;
CREATE INDEX idx_zipid ON dailymed_idx(zipid2);

CREATE TABLE tmp AS
EXPLAIN ANALYZE SELECT fdadrugs_idx.*, dailymed_idx.* FROM
( SELECT prodid2 FROM fdadrugs_idx GROUP BY prodid2 ) AS fdadrugs_idx
LEFT JOIN
dailymed_idx
ON fdadrugs_idx.prodid2 LIKE dailymed_idx.zipid2;

EXPLAIN SELECT fdadrugs_idx.*, dailymed_idx.* FROM
fdadrugs_idx
LEFT JOIN
dailymed_idx
ON fdadrugs_idx.prodid2 LIKE dailymed_idx.zipid2;

-------------------------------------------------*/

