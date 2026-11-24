-- =====================================================================
-- ICT371 Advanced Database  |  Question 10: Scholarship Application Assessment
-- DBMS: PostgreSQL 14+   |  Scheduler: pg_cron extension
-- Qualify only if age 18-25 inclusive, monthly income <= K3,000, mark >= 70.
-- =====================================================================

-- (a) Database and seed data
DROP TABLE IF EXISTS decision_audit CASCADE;
DROP TABLE IF EXISTS applications   CASCADE;
DROP TABLE IF EXISTS students       CASCADE;

CREATE TABLE students (
    student_id     INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    student_number VARCHAR(20)  NOT NULL UNIQUE,
    full_name      VARCHAR(100) NOT NULL
);

CREATE TABLE applications (
    application_id     INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    student_id         INT NOT NULL REFERENCES students(student_id),
    age_at_application INT NOT NULL CHECK (age_at_application > 0),
    monthly_income     NUMERIC(10,2) NOT NULL CHECK (monthly_income >= 0),
    average_mark       NUMERIC(5,2)  NOT NULL CHECK (average_mark BETWEEN 0 AND 100),
    submitted_on       DATE NOT NULL DEFAULT CURRENT_DATE,
    status             VARCHAR(10) NOT NULL DEFAULT 'PENDING',
    CONSTRAINT ck_app_status CHECK (status IN ('PENDING', 'APPROVED', 'REJECTED'))
);

CREATE TABLE decision_audit (
    audit_id       INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    application_id INT NOT NULL REFERENCES applications(application_id),
    old_status     VARCHAR(10) NOT NULL,
    new_status     VARCHAR(10) NOT NULL,
    changed_at     TIMESTAMP   NOT NULL DEFAULT now()
);

INSERT INTO students (student_number, full_name) VALUES
    ('SC2026001', 'Kelvin Mumba'),
    ('SC2026002', 'Lydia Chama'),
    ('SC2026003', 'Moses Sinkala'),
    ('SC2026004', 'Dorothy Lungu');   -- no application

-- Six PENDING applications: normal pass, boundary passes and failures
INSERT INTO applications (student_id, age_at_application, monthly_income, average_mark, submitted_on) VALUES
    (1, 20, 2000.00, 80.00, CURRENT_DATE - 10),   -- 1 qualifies
    (1, 18, 3000.00, 70.00, CURRENT_DATE -  9),   -- 2 boundary: min age, max income, min mark -> qualifies
    (2, 25, 2500.00, 75.00, CURRENT_DATE -  8),   -- 3 boundary: max age -> qualifies
    (2, 26, 1000.00, 90.00, CURRENT_DATE -  7),   -- 4 too old
    (3, 22, 3000.01, 90.00, CURRENT_DATE -  6),   -- 5 income just above limit
    (3, 19, 1500.00, 69.99, CURRENT_DATE -  5);   -- 6 mark just below limit

-- (b) Function
CREATE OR REPLACE FUNCTION fn_scholarship_eligible(p_age INT, p_income NUMERIC, p_mark NUMERIC)
RETURNS BOOLEAN
LANGUAGE plpgsql IMMUTABLE
AS $$
BEGIN
    IF p_age IS NULL OR p_income IS NULL OR p_mark IS NULL THEN
        RAISE EXCEPTION 'Age, income and mark must not be NULL';
    END IF;
    IF p_age <= 0 THEN
        RAISE EXCEPTION 'Age must be positive (got %)', p_age;
    END IF;
    IF p_income < 0 THEN
        RAISE EXCEPTION 'Income must not be negative (got %)', p_income;
    END IF;
    IF p_mark < 0 OR p_mark > 100 THEN
        RAISE EXCEPTION 'Mark must be between 0 and 100 (got %)', p_mark;
    END IF;

    RETURN p_age BETWEEN 18 AND 25
       AND p_income <= 3000
       AND p_mark >= 70;
END;
$$;

-- (d) Trigger: audit actual status changes
CREATE OR REPLACE FUNCTION trg_fn_decision_audit()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    INSERT INTO decision_audit (application_id, old_status, new_status, changed_at)
    VALUES (NEW.application_id, OLD.status, NEW.status, now());
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_decision_audit ON applications;
CREATE TRIGGER trg_decision_audit
AFTER UPDATE ON applications
FOR EACH ROW
WHEN (OLD.status IS DISTINCT FROM NEW.status)
EXECUTE FUNCTION trg_fn_decision_audit();

-- (c) Procedure
CREATE OR REPLACE PROCEDURE pr_assess_application(p_application_id INT)
LANGUAGE plpgsql
AS $$
DECLARE
    rec RECORD;
BEGIN
    SELECT age_at_application, monthly_income, average_mark, status INTO rec
    FROM applications
    WHERE application_id = p_application_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown application_id: %', p_application_id;
    END IF;
    IF rec.status <> 'PENDING' THEN
        RAISE EXCEPTION 'Application % has already been assessed (status %)',
                        p_application_id, rec.status;
    END IF;

    UPDATE applications
    SET status = CASE
                     WHEN fn_scholarship_eligible(rec.age_at_application,
                                                  rec.monthly_income,
                                                  rec.average_mark)
                     THEN 'APPROVED' ELSE 'REJECTED'
                 END
    WHERE application_id = p_application_id;
END;
$$;

-- Function checks
SELECT application_id,
       fn_scholarship_eligible(age_at_application, monthly_income, average_mark) AS eligible
FROM applications ORDER BY application_id;

-- Invalid function inputs (expected to fail)
DO $$ BEGIN PERFORM fn_scholarship_eligible(NULL, 1000, 80);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Expected error: %', SQLERRM; END $$;
DO $$ BEGIN PERFORM fn_scholarship_eligible(20, -1, 80);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Expected error: %', SQLERRM; END $$;
DO $$ BEGIN PERFORM fn_scholarship_eligible(0, 1000, 80);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Expected error: %', SQLERRM; END $$;
DO $$ BEGIN PERFORM fn_scholarship_eligible(20, 1000, 101);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Expected error: %', SQLERRM; END $$;

-- Assess one application, then try to assess it again / an unknown one
CALL pr_assess_application(1);
DO $$ BEGIN CALL pr_assess_application(1);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Expected error: %', SQLERRM; END $$;
DO $$ BEGIN CALL pr_assess_application(999);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Expected error: %', SQLERRM; END $$;

-- Trigger: an update that does not change status creates no audit row
UPDATE applications SET status = status WHERE application_id = 1;
SELECT * FROM decision_audit ORDER BY audit_id;   -- exactly 1 row

-- (g) Scheduled job: query FOR loop over PENDING applications only
CREATE OR REPLACE PROCEDURE pr_assess_pending()
LANGUAGE plpgsql
AS $$
DECLARE
    rec RECORD;
BEGIN
    FOR rec IN
        SELECT application_id
        FROM applications
        WHERE status = 'PENDING'
        ORDER BY application_id
    LOOP
        CALL pr_assess_application(rec.application_id);
    END LOOP;
END;
$$;

CALL pr_assess_pending();     -- assesses applications 2-6
CALL pr_assess_pending();     -- rerun: nothing pending, no changes, no duplicate audit rows
SELECT application_id, status FROM applications ORDER BY application_id;
SELECT COUNT(*) AS audit_rows_should_be_6 FROM decision_audit;

-- (e) View: APPROVED only, no income column
CREATE OR REPLACE VIEW v_approved_applicants AS
SELECT s.student_number,
       s.full_name,
       a.average_mark,
       a.status
FROM applications a
JOIN students s ON s.student_id = a.student_id
WHERE a.status = 'APPROVED';

SELECT * FROM v_approved_applicants;

-- (f) Index
-- Justification: the search has an equality on status and a range on
-- submitted_on. Putting the equality column first and the range column second
-- lets the B-tree jump to one status and scan only the date window in order.
CREATE INDEX idx_app_status_submitted ON applications (status, submitted_on);
ANALYZE applications;

SET enable_seqscan = off;   -- tiny table: force the planner to show the index
EXPLAIN
SELECT application_id, student_id, submitted_on
FROM applications
WHERE status = 'PENDING'
  AND submitted_on BETWEEN CURRENT_DATE - 30 AND CURRENT_DATE;
RESET enable_seqscan;

CREATE EXTENSION IF NOT EXISTS pg_cron;

-- Every Monday at 08:00
SELECT cron.schedule(
    'scholarship_assess_pending',
    '0 8 * * 1',
    $job$CALL pr_assess_pending()$job$
);

SELECT jobid, jobname, schedule, command FROM cron.job;
