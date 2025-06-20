/*
  Script: convert_jenzabar_to_sgbstdn.sql
  Purpose: Convert student enrollment data from Jenzabar to SGBSTDN format for Ellucian Banner
  Author: Nipit Pongpan
  Date: 2025-06-19
  Requirements:
    - MS SQL Server
    - Tables: student_crs_hist, degree_history, major_minor_def, ID_PIDM_BAN_ID, etc.
    - Reference mapping from banner_degree_map
*/



-- ====================================================================================
-- CTE: term_table
-- Purpose:
--   Extend each term’s end date to ensure continuous coverage of dates.
--   This helps associate dates (e.g., degree entry, exit, conferral, withdrawal)
--   with a valid academic term—even if those dates fall between official term ranges.
-- Logic:
--   - Uses LEAD() to find the next term's start date
--   - Subtracts 1 day from that to set the "extended end date"
--   - Filters out test/dummy years like 'ZZZZ'
-- ====================================================================================


with  term_table AS 

(
        SELECT 
                DATEADD(DAY,-1,(LEAD(trm_begin_dte) OVER(ORDER BY trm_begin_dte))) AS extend_trm_end_dte,
                *
                
        FROM 

                year_term_table 


        WHERE      

                yr_cde <> 'ZZZZ'

),

major_table AS 

(

        SELECT 

                major_cde,      
                CASE WHEN major_cde = 'LAR' THEN 'NDA' ELSE degr_cde END AS degr_cde
        

FROM 

        major_minor_def 
),


-- ====================================================================================
-- Purpose of `sudo_term`:
--   Jenzabar uses academic year + separate term codes (e.g., FA/SP/SU), such as:
--     - Academic year: 2425
--     - Term code: 'SP' (Spring)
--   Banner uses a numeric 6-digit term code in the format: YYYYMM
--     - YYYY = calendar year
--     - MM = starting month of the term (e.g., 01 for Spring, 05 for Summer, 08 for Fall)
--
--   To align with Banner’s format, we generate a synthetic 'sudo_term' using:
--     - term_table.trm_begin_dte formatted as YYYYMM (converted to INT)
--     - This enables easier mapping and transformation for Banner-compatible term codes
-- ====================================================================================


term_sum_data AS 

(

        SELECT 
                sch.id_num,

                CAST(FORMAT(term_Table.trm_begin_dte,'yyyyMM') AS INT) AS sudo_term,
                SUM(sch.hrs_attempted) AS sum_hrs_attempted

        FROM 
                student_crs_hist AS sch
                LEFT JOIN term_table  ON sch.yr_cde = term_table.yr_cde AND sch.trm_cde = term_table.trm_cde

        GROUP BY 

                sch.id_num,
                CAST(FORMAT(term_Table.trm_begin_dte,'yyyyMM') AS INT) 

),

candidacy_hist AS 

(

        SELECT  


                id_num, 
                candidacy.yr_cde, 
                candidacy.trm_cde, 
                LOAD_P_F, 
                candidacy_type,
                term_table.trm_begin_dte,
                term_table.trm_end_dte,
                term_table.extend_trm_end_dte,
                CAST(FORMAT(trm_begin_dte,'yyyyMM') AS INT) AS sudo_term
                
        FROM  
                candidacy 
                LEFT JOIN term_table  ON candidacy.yr_cde = term_table.yr_cde AND candidacy.trm_cde = term_table.trm_cde

        WHERE 

                (candidacy.yr_cde <> 'ZZZZ'
                OR candidacy.trm_cde <> 'ZZ') 


),


-- ====================================================================================
-- CTE: term_first
-- Purpose:
--   Identify the first **active/enrolled** term for each student.
--
-- Logic:
--   - Joins student course history (student_crs_hist) with term_table
--   - Filters out:
--       - Dropped transactions ('D')
--       - Transfer grades ('T', 'TU')
--       - Non-credit terms (credit_hrs <= 0)
--       - Transfer terms (trm_cde = 'TR') and transfer year codes (yr_cde = 'TRAN')
--   - Uses MIN(term start date) to get the first actual enrollment
--
-- Output:
--   - `id_num`
--   - `first_term_date` – the earliest valid enrollment date
-- ====================================================================================

 term_first AS 

(

        SELECT 

        sch.id_num,
        MIN(term_table.trm_begin_dte) AS first_term_date
 
        FROM 

                student_crs_hist AS sch 
                LEFT JOIN term_table  ON sch.yr_cde = term_table.yr_cde AND sch.trm_cde = term_table.trm_cde

        WHERE  

                sch.transaction_sts <> 'D'
                AND (sch.grade_cde NOT IN ('T','TU'))
                AND sch.credit_hrs > 0
                AND sch.trm_cde <> 'TR'
                AND sch.yr_cde <> 'TRAN'

        GROUP BY 

                id_num
                
),

term_first_with_sudo_term AS 
(
        SELECT 
                *,
                CAST(FORMAT(first_term_date,'yyyyMM') AS INT) AS sudo_term
        FROM 
                term_first
),


-- ====================================================================================
-- CTE: term_last
-- Purpose:
--   Identify the last **active/enrolled** term for each student.
--
-- Logic:
--   - Same filters as `term_first`
--   - Uses MAX(term start date) to get the most recent valid enrollment
--
-- Output:
--   - `id_num`
--   - `last_term_date` – the latest term the student was actively enrolled in
-- ====================================================================================


term_last AS 

(

SELECT 

    sch.id_num,
    MAX(term_table.trm_begin_dte) AS  last_term_date
    
    

FROM 

        student_crs_hist AS sch 
        LEFT JOIN term_table  ON sch.yr_cde = term_table.yr_cde AND sch.trm_cde = term_table.trm_cde

WHERE  

        sch.transaction_sts <> 'D'
        AND (sch.grade_cde NOT IN ('T','TU') )
        AND sch.credit_hrs > 0
        AND sch.trm_cde <> 'TR'
        AND sch.yr_cde <> 'TRAN'

GROUP BY 

        id_num

),


-- ====================================================================================
-- CTE: degree_history_sig_date
-- Purpose:
--   Extract significant milestone dates from the degree_history table for each student.
--   These include:
--     - Entry date (when a student began a program)
--     - Exit date (when a student left a program)
--     - Degree conferred date (when a degree was awarded)
--     - Withdrawal date (if the student withdrew)
-- 
--   These dates are later used to:
--     - Construct a timeline of enrollment and degree activity
--     - Map each date to a term (via term_table)
--     - Generate indicators like start term, last term, etc.
--
-- Structure:
--   - Each SELECT pulls a different date and labels it using `sig_desc`
--   - Columns like `major_1`, `degr_cde`, `div_cde`, etc. are kept for later mapping
--   - Uses UNION to stack all event types into one dataset
-- ====================================================================================

degree_history_sig_date AS 


(

        SELECT 
                id_num,
                entry_dte AS sig_date,
                'entry date' AS sig_desc,
                '' AS reason_code,
                major_1,
                degr_cde,
                div_cde,
                major_2,
                concentration_1
                
        FROM 
                degree_history
        
        UNION 

        SELECT 
                id_num, 
                exit_dte,
                'exit date' AS sig_desc,
                exit_reason AS reason_code,
                major_1,
                degr_cde,
                div_cde,
                major_2,
                concentration_1
                
                
        FROM 
                degree_history
                
        
        UNiON 
        
        SELECT 
                id_num,
                dte_degr_conferred,
                'degree conferred date' AS sig_desc,
                '' AS reason_code,
                major_1,
                degr_cde,
                div_cde,
                major_2,
                concentration_1
        FROM 

                degree_history 

        UNION 

        SELECT 

                id_num,
                withdrawal_dte,
                'withdrawal date' AS sig_desc, 
                '' AS reason_code,
                major_1,
                degr_cde,
                div_cde,
                major_2,
                concentration_1
                

        FROM 

                degree_history 

),

combine_sig_date AS

(

        SELECT 
                        
                        * 

        FROM 

                        degree_history_sig_date

        WHERE 

                        sig_date IS NOT NULL
        UNION 

        SELECT  

                *,'start enroll' AS sig_desc, '','','','','',''


        FROM 

                term_first 
        
        UNION 

        SELECT 
                *, 'last enroll' AS sig_desc , '','','','','',''


        FROM 
                term_last 


), 
combine_sig_date_add_sudo_term AS 
(
        SELECT 

                *,
                CAST(FORMAT(term_table.trm_begin_dte,'yyyyMM') AS INT) AS sudo_term

                
        FROM 

                combine_sig_date
                LEFT JOIN term_table ON combine_sig_date.sig_date BETWEEN term_table.trm_begin_dte AND term_table.extend_trm_end_dte



),
combine_sig_date_add_sudo_term_map_major AS
(

        SELECT 
                DISTINCT 
                id_num,
                sudo_term,
                TRIM(major_1) AS major_1,
                mmd.degr_cde AS mmd_degr_cde,
                TRIM(major_2) AS major_2,
                mmd2.degr_cde AS mmd2_degr_cde,
                TRIM(concentration_1) AS concentration_1,
                c.degr_cde
                

        FROM 
                combine_sig_date_add_sudo_term AS c
                LEFT JOIN major_table AS mmd ON c.major_1 = mmd.major_cde
                LEFT JOIN major_table AS mmd2 ON c.major_2 = mmd2.major_cde

        
),

combine_sig_date_add_sudo_term_map_degree AS 
(

        SELECT 
                DISTINCT 
                id_num,
                sudo_term,
                TRIM(c.degr_cde) AS degr_cde,

                CASE 

                        WHEN c.div_cde = 'U' THEN 3
                        WHEN c.degr_cde IN ('A','AGS','BA','BS','BSW','S') THEN 3 
                        WHEN c.degr_cde  = 'V' THEN 2 
                        WHEN c.degr_cde = 'C' THEN 1
                        WHEN c.degr_cde = 'NDA' THEN 0
                        WHEN c.div_cde = 'A' THEN -1
                
                END AS degree_level 
        FROM 
                combine_sig_date_add_sudo_term AS c
                LEFT JOIN major_table AS mmd ON c.major_1 = mmd.major_cde

        
),
group_term_major AS 
(

        SELECT 

                id_num,
                sudo_term,
                STRING_AGG(major_1,';') as agg_major_1,
                STRING_AGG(major_2,';') as agg_major_2,
                STRING_AGG(concentration_1,';') as agg_concentration_1

        FROM 

                combine_sig_date_add_sudo_term_map_major

        GROUP BY 

                id_num,
                sudo_term
),
group_term_degree AS 
(

        SELECT 

                id_num,
                sudo_term,
                STRING_AGG(degr_cde, ';') AS agg_degree_code, 
                MAX(degree_level) AS highest_degree

        FROM 

                combine_sig_date_add_sudo_term_map_degree

        GROUP BY 

                id_num,
                sudo_term

),
group_term AS 
(
        SELECT 

                id_num,  
                sudo_term,
                string_agg(sig_desc,';') agg_sig_desc,
                string_agg(reason_code,';') agg_reason_code

        FROM 

                combine_sig_date_add_sudo_term 


        WHERE 
                id_num  IN (SELECT id_num FROM extracted_recs) 



        GROUP BY 

                id_num, sudo_term
),
count_row_group_term AS 
(
        SELECT id_num, COUNT(*) count_row FROM group_term GROUP BY id_num
),
rank_credit_type AS 
(
        SELECT  
                DISTINCT
                sch.id_num,
                sch.credit_type_cde,
                CAST(FORMAT(term_table.trm_begin_dte,'yyyyMM') AS INT) AS sudo_term,


                CASE credit_type_cde 

                WHEN 'CR' THEN 3
                WHEN 'VO' THEN 2 
                WHEN 'CE' THEN 1 
                END AS credit_type_rank



        FROM 
                student_crs_hist AS sch
                LEFT JOIN  term_table  ON sch.yr_cde = term_table.yr_cde AND sch.trm_cde = term_table.trm_cde


        WHERE 

                        sch.transaction_sts <> 'D'
                        AND grade_cde NOT IN ('T','TU')
                        AND credit_hrs > 0
                        AND sch.trm_cde <> 'TR'
                        AND sch.yr_cde <> 'TRAN'

),
group_credit_type_rank AS 
(
    SELECT  
            id_num, 
            sudo_term, 
            max(credit_type_rank) AS max_credit_type_rank 
    FROM 
            rank_credit_type

    GROUP BY 
            id_num, 
            sudo_term
)

, stst AS 
(
SELECT 


        CASE 
                WHEN term_sum_data.sum_hrs_attempted>= 12 THEN 'F'
                WHEN term_sum_data.sum_hrs_attempted > 0 AND term_sum_data.sum_hrs_attempted < 12 THEN 'P'
               
                WHEN term_sum_data.sum_hrs_attempted IS NULL  AND (ROW_NUMBER() OVER(PARTITION BY group_term.id_num ORDER BY group_term.sudo_term) = 1 )  
                        THEN 
                                CASE 
                                    WHEN LEAD(term_sum_data.sum_hrs_attempted) OVER(PARTITION BY group_term.id_num ORDER BY group_term.sudo_term) >=12 THEN 'F'
                                    WHEN LEAD(term_sum_data.sum_hrs_attempted) OVER(PARTITION BY group_term.id_num ORDER BY group_term.sudo_term) > 0 
                                                        AND  LEAD(term_sum_data.sum_hrs_attempted) OVER(PARTITION BY group_term.id_num ORDER BY group_term.sudo_term) < 12 THEN 'P'
                                    WHEN candidacy_hist.load_p_f IS NOT NULL THEN candidacy_hist.load_p_f
                                    ELSE 'F'
                                END
                WHEN term_sum_data.sum_hrs_attempted IS NULL  AND (ROW_NUMBER() OVER(PARTITION BY group_term.id_num ORDER BY group_term.sudo_term) > 1 )  
                        THEN 
                        
                        
                                CASE 
                                    WHEN LAG(term_sum_data.sum_hrs_attempted) OVER(PARTITION BY group_term.id_num ORDER BY group_term.sudo_term) >=12 THEN 'F'
                                    WHEN LAG(term_sum_data.sum_hrs_attempted) OVER(PARTITION BY group_term.id_num ORDER BY group_term.sudo_term) > 0 
                                                        AND  LAG(term_sum_data.sum_hrs_attempted) OVER(PARTITION BY group_term.id_num ORDER BY group_term.sudo_term) < 12 THEN 'P'
                                    WHEN candidacy_hist.load_p_f IS NOT NULL THEN candidacy_hist.load_p_f
                                    ELSE 'F'
                                END      

                WHEN candidacy_hist.load_p_f IS NOT NULL THEN candidacy_hist.load_p_f 
                ELSE 'F'
        END
        AS ft_pt_ind,

        candidacy_hist.load_p_f,
        candidacy_hist.candidacy_type,
        CASE 
                WHEN EXISTS(SELECT * FROM student_crs_hist AS sch WHERE id_num = group_term.id_num AND (sch.yr_cde = 'TRAN' OR sch.trm_cde = 'TR')) 
                                THEN 'Y' 
                ELSE 'N'
        END AS is_transfer,
        
        CASE 
                WHEN (SELECT sudo_term FROM term_first_with_sudo_term  WHERE id_num = group_term.id_num) = group_term.sudo_term
                                THEN 'Y' 
                ELSE 'N'
        END AS is_first_term ,

        group_term_major.agg_major_1,
        group_term_major.agg_major_2,
        group_term_major.agg_concentration_1,
        group_term_degree.agg_degree_code,
        group_term.agg_sig_desc,
        group_term.agg_reason_code,
        CASE WHEN CHARINDEX('entry date',group_term.agg_sig_desc) > 0 OR CHARINDEX('start enroll',group_term.agg_sig_desc) > 0 THEN 1  
        END AS start_hist,
         CASE WHEN CHARINDEX('entry date',group_term.agg_sig_desc) > 0 OR CHARINDEX('start enroll',group_term.agg_sig_desc) > 0 THEN group_term.sudo_term
        END AS start_term,       

        --CASE  WHEN CHARINDEX('entry date',group_term.agg_sig_desc) > 0 OR CHARINDEX('start enroll',group_term.agg_sig_desc) > 0   --ROW_NUMBER() OVER(PARTITION BY group_term.id_num ORDER BY group_term.sudo_term) = 1 
             --                   THEN 
                                        CASE 
                                                WHEN group_term_degree.highest_degree < 3 --CHARINDEX('NDA',agg_degree_code) > 0 OR CHARINDEX('V',agg_degree_code) > 0
                                                        AND CHARINDEX(';A;',agg_degree_code) = 0
                                                        AND CHARINDEX('S',agg_degree_code) = 0 
                                                        AND CHARINDEX('BA',agg_degree_code) = 0 
                                                        AND CHARINDEX('BS',agg_degree_code) = 0
                                                        THEN '9'
                                                WHEN NOT(EXISTS(SELECT * FROM student_crs_hist AS sch WHERE id_num = group_term.id_num AND (sch.yr_cde = 'TRAN' OR sch.trm_cde = 'TR'))) THEN '3' 
                                                WHEN EXISTS(SELECT * FROM student_crs_hist AS sch WHERE id_num = group_term.id_num AND (sch.yr_cde = 'TRAN' OR sch.trm_cde = 'TR'))  THEN '2'

                                        --END 
        END as ini_styp,

        ROW_NUMBER() OVER(PARTITION BY group_term.id_num ORDER BY group_term.sudo_term) AS row_num,
        
        count_row_group_term.count_row,
        CASE WHEN EXISTS(SELECT distinct id_num 
                        from student_crs_hist where transaction_sts <> 'D' and yr_cde = '2425' and trm_cde in ('SP','SU') and credit_hrs > 0  and id_num =group_term.id_num ) THEN 'Y' 
                END AS is_active,
    

        group_term.id_num AS  sac_id,
        group_term.sudo_term  AS term_code_eff,

        CASE 
                WHEN count_row_group_term.count_row = 1 THEN 'AS'

                WHEN ROW_NUMBER() OVER(PARTITION BY group_term.id_num ORDER BY group_term.sudo_term) = count_row_group_term.count_row AND group_term.sudo_term  < 202501 THEN 'IS'

                WHEN (CHARINDEX('last enroll',group_term.agg_sig_desc) > 0 OR CHARINDEX('withdrawal date',group_term.agg_sig_desc) > 0) AND group_term.sudo_term  < 202501 THEN 'IS' 
                
                WHEN (CHARINDEX('last enroll',group_term.agg_sig_desc) > 0 OR CHARINDEX('withdrawal date',group_term.agg_sig_desc) > 0)  AND group_term.sudo_term  IN  (202501,202506) THEN 'AS' 

                WHEN CHARINDEX('start enroll',group_term.agg_sig_desc) > 0  THEN 'AS'
                
                WHEN CHARINDEX('entry date',group_term.agg_sig_desc) > 0 THEN 'AS'

                WHEN CHARINDEX('exit date',group_term.agg_sig_desc) > 0 THEN 'AS'

                WHEN CHARINDEX('degree conferred date',group_term.agg_sig_desc) > 0 THEN 'GR' 

                               

        END AS stst_code,


        CASE 
                WHEN group_term_degree.highest_degree = -1 THEN 'XX'  -- Adult Education Division
                WHEN group_term_degree.highest_degree = 3 THEN 'UG'
                WHEN group_term_degree.highest_degree = 2 THEN 'VO'
                WHEN group_term_degree.highest_degree = 1 THEN 'CE'
                WHEN group_term_degree.highest_degree IS NULL AND CHARINDEX('last enroll',group_term.agg_sig_desc) > 0 AND CHARINDEX('start enroll',group_term.agg_sig_desc) > 0
                        THEN 
                                CASE (SELECT max_credit_type_rank FROM group_credit_type_rank  WHERE id_num = group_term.id_num ANd sudo_term= group_term.sudo_term)
                                        WHEN 3 THEN 'UG'
                                        WHEN 2 THEN 'VO'
                                        WHEN 1 tHEN 'CE'
                                        ELSE '00'

                                END

                WHEN group_term_degree.highest_degree IS NULL AND CHARINDEX('last enroll',group_term.agg_sig_desc) > 0 
                                        THEN 
                                                CASE 
                                                        WHEN LAG(group_term_degree.highest_degree)  OVER(PARTITION BY group_term.id_num ORDER BY group_term.sudo_term) IS NULL 
                                                                THEN 
                                                                        CASE (SELECT max_credit_type_rank FROM group_credit_type_rank  WHERE id_num = group_term.id_num ANd sudo_term= group_term.sudo_term)
                                                                                WHEN 3 THEN 'UG'
                                                                                WHEN 2 THEN 'VO'
                                                                                WHEN 1 tHEN 'CE'
                                                                                ELSE '00'

                                                                        END
                                                ELSE

                                                        CASE LAG(group_term_degree.highest_degree)  OVER(PARTITION BY group_term.id_num ORDER BY group_term.sudo_term)
                                                                WHEN 3 THEN 'UG'
                                                                WHEN 2 THEN 'VO'
                                                                WHEN 1 tHEN 'CE'
                                                                ELSE CAST(LAG(group_term_degree.highest_degree)  OVER(PARTITION BY group_term.id_num ORDER BY group_term.sudo_term) AS CHAR(1))--'00'
                                                        END 
                                                END
                WHEN group_term_degree.highest_degree IS NULL AND CHARINDEX('start enroll',group_term.agg_sig_desc) > 0 
                                THEN 
                                        CASE 
                                                WHEN    CHARINDEX('entry date',LAG(group_term.agg_sig_desc) OVER(PARTITION BY group_term.id_num ORDER BY group_term.sudo_term)) > 0 
                                                                        THEN 
                                                                                CASE LAG(group_term_degree.highest_degree)  OVER(PARTITION BY group_term.id_num ORDER BY group_term.sudo_term)
                                                                                        WHEN 3 THEN 'UG'
                                                                                        WHEN 2 THEN 'VO'
                                                                                        WHEN 1 tHEN 'CE'
                                                                                        ELSE '00'
                                                                                END 

                                                
                                                WHEN   CHARINDEX('entry date',LEAD(group_term.agg_sig_desc) OVER(PARTITION BY group_term.id_num ORDER BY group_term.sudo_term)) > 0 

                                                                THEN 
                                                                        CASE LEAD(group_term_degree.highest_degree)  OVER(PARTITION BY group_term.id_num ORDER BY group_term.sudo_term)
                                                                                WHEN 3 THEN 'UG'
                                                                                WHEN 2 THEN 'VO'
                                                                                WHEN 1 tHEN 'CE'
                                                                                ELSE '00'
                                                                        END 
                                                ELSE  
                                                        CASE (SELECT max_credit_type_rank FROM group_credit_type_rank  WHERE id_num = group_term.id_num ANd sudo_term= group_term.sudo_term)
                                                                WHEN 3 THEN 'UG'
                                                                WHEN 2 THEN 'VO'
                                                                WHEN 1 tHEN 'CE'
                                                                ELSE '00'

                                                        END
                                END
        END AS levl_code
FROM 
        group_term 
        LEFT JOIN group_term_major ON group_term.id_num = group_term_major.id_num ANd group_term.sudo_term = group_term_major.sudo_term
        LEFT JOIN group_term_degree ON group_term.id_num = group_term_degree.id_num ANd group_term.sudo_term = group_term_degree.sudo_term
        LEFT JOIN count_row_group_term ON group_term.id_num = count_row_group_term.id_num
        LEFT JOIN candidacy_hist ON group_term.id_num = candidacy_hist.id_num AND group_term.sudo_term = candidacy_hist.sudo_term
        LEFT JOIN term_sum_data ON group_term.id_num = term_sum_data.id_num AND group_term.sudo_term = term_sum_data.sudo_term

WHERE 
        group_term.id_num IN (SELECT DISTINCT id_num FROM student_crs_hist WHERE hrs_attempted > 0 AND trm_cde <> 'TR' AND yr_cde <> 'TRAN' and grade_cde NOT IN ('T','TU') ANd transaction_sts <> 'D')

),
stst_hist_group AS 
(
        SELECT 

                SUM(CASE WHEN start_hist = 1 THEN 1 ELSE 0 END) OVER (PARTITION BY sac_id ORDER BY row_num) AS hist_group,

                *
                
        FROM 

                stst 
             
),
styp AS 
(
        SELECT 
                *,

                CASE
                        WHEN start_hist IS NULL  AND LAG(ini_styp) OVER(PARTITION BY sac_id ORDER BY term_code_eff) = '9' THEN 'C'
                        WHEN LAG(ini_styp) OVER(PARTITION BY sac_id ORDER BY term_code_eff)  IN ('2','3') THEN 'A'
                        WHEN start_hist IS NOT NULL THEN ini_styp 
                        ELSE ini_styp
                        
                END  AS styp_code,             

                '' AS term_code_matric, -- Not require

                FIRST_VALUE(stst_hist_group.start_term) OVER(PARTITION BY stst_hist_group.sac_id,stst_hist_group.hist_group ORDER BY stst_hist_group.sac_id,stst_hist_group.term_code_eff) AS term_code_admit, 

                '' AS exp_grad_date, -- Not require

                'SAC' As camp_code,        
        
                FIRST_VALUE(stst_hist_group.ft_pt_ind) OVER(PARTITION BY stst_hist_group.sac_id,stst_hist_group.hist_group ORDER BY stst_hist_group.sac_id,stst_hist_group.term_code_eff)  AS full_part_ind, 

                '' AS sess_code,

                'C' AS resd_code
        
        FROM 
                stst_hist_group
), 
term_major_1_2_union AS 
(
        SELECT DISTINCT * FROM 
        (
                SELECT  
                        id_num, 
                        sudo_term, 
                        major_1 ,
                        mmd_degr_cde,
                        degr_cde AS degree_history_degr_cde,
                        concentration_1
                FROM 
                        combine_sig_date_add_sudo_term_map_major
                WHERE 
                        NOT(major_1 IS NULL  OR major_1 = '')
                UNION 
                SELECT 
                        id_num, 
                        sudo_term, 
                        major_2,
                        mmd2_degr_cde,
                        degr_cde AS degree_history_degr_cde ,
                        concentration_1
                FROM 
                        combine_sig_date_add_sudo_term_map_major

                WHERE 
                        NOT(major_2 IS NULL  OR major_2 = '')

        ) AS temp_table

),
term_major_excl_cert  AS 
(
        SELECT * FROM term_major_1_2_union WHERE mmd_degr_cde NOT IN ('V','C')
),

term_major_cert AS 
(

        SELECT * FROM term_major_1_2_union WHERE mmd_degr_cde  IN ('V','C')
),
count_degree AS 
(
        SELECT id_num, sudo_term, COUNT(*) AS count_degree FROM term_major_excl_cert  GROUP BY id_num, sudo_term
),
term_major_excl_cert_add_row_num AS 
(
        SELECT 
                ROW_NUMBER() OVER(PARTITION BY id_num,sudo_term ORDER BY id_num,sudo_term) AS row_num,
                *
        FROM 
                term_major_excl_cert
) ,
converted_degree AS 
(
        SELECT 
                degree1.id_num,
                degree1.sudo_term,
                degree1.major_1,
                degree1.concentration_1 as degree1_conentration,
                degree1.mmd_degr_cde AS degree1,
                ISNULL(degree1.mmd_degr_cde,'') + ISNULL(degree1.major_1,'')  + ISNULL(degree1.concentration_1,'') AS degree_map1,

                degree2.major_1 AS major_2,
                degree2.mmd_degr_cde AS degree2,
                ISNULL(degree2.mmd_degr_cde,'') + ISNULL(degree2.major_1,'')  + ISNULL(degree2.concentration_1,'') AS degree_map2
        FROM 
        (
                SELECT 
                        *
                FROM 
                        term_major_excl_cert_add_row_num 
                WHERE 
                        row_num = 1

        ) degree1 

        LEFT JOIN 

                ( 
                        SELECT 
                                *
                        FROM 
                                term_major_excl_cert_add_row_num 

                        WHERE 

                                row_num = 2

                ) degree2  ON degree1.id_num = degree2.id_num AND degree1.sudo_term = degree2.sudo_term
),
term_major_cert_add_row_num AS 
(
        SELECT 
                ROW_NUMBER() OVER(PARTITION BY id_num,sudo_term ORDER BY id_num,sudo_term) AS row_num,
                *
        FROM 

                term_major_cert
), 
converted_cert AS 
(
        SELECT 
                cert1.id_num,
                cert1.sudo_term,
                cert1.major_1 AS cert_1_code,
                cert1.mmd_degr_cde AS cert1_degr_cde,
                ISNULL(cert1.mmd_degr_cde,'') + ISNULL(cert1.major_1,'')  + ISNULL(cert1.concentration_1,'') AS cert_map1,

                cert2.major_1 AS cert_2_code,
                cert2.mmd_degr_cde AS cert_2_degr_cde,
                ISNULL(cert1.mmd_degr_cde,'') + ISNULL(cert1.major_1,'')   AS cert_map2

        FROM 
        (
                SELECT 
                        *
                FROM 
                        term_major_cert_add_row_num 


                WHERE 

                        row_num = 1

        ) cert1

        LEFT JOIN 

                ( 
                                SELECT 
                                        *
                                FROM 
                                        term_major_cert_add_row_num 


                                WHERE 

                                        row_num = 2

                ) cert2  ON cert1.id_num = cert2.id_num AND cert1.sudo_term = cert2.sudo_term

),
mapped_degree AS 
( 
        SELECT 

                        styp.*,
                        
                        CASE 
                                WHEN is_active = 'Y' THEN degree_map1.College
                                WHEN is_active IS NULL THEN  degree_map1_i.sgbstdn_coll_code_1

                        END AS coll_code_1,

                        CASE 
                                WHEN is_active = 'Y' THEN degree_map1.Degree 
                                WHEN is_active IS NULL THEN  degree_map1_i.sgbstdn_degc_code_1
                                
                        END AS degc_code_1,

                        CASE  
                                WHEN is_active = 'Y' THEN degree_map1.sgbstdn_majr_code_1 
                                WHEN is_active IS NULL THEN  converted_degree.major_1

                        END AS majr_code_1,    


                       
                        '' AS majr_code_minr_1,

                        '' AS majr_code_minr_1_2,

                        CASE WHEN is_active = 'Y' 
                                THEN degree_map1.sgbstdn_majr_code_conc_1 
                        END AS majr_code_conc_1,

                        '' AS majr_code_conc_1_2,
                        '' AS majr_code_conc_1_3,

                        CASE
                            WHEN converted_degree.degree1 <> converted_degree.degree2 THEN 
                                                        CASE 
                                                        WHEN is_active = 'Y' THEN degree_map2.College 
                                                        WHEN is_active IS NULL THEN  degree_map2_i.sgbstdn_coll_code_1
                                                        END 

                        END AS coll_code_2,
                        



                        CASE 
                            WHEN converted_degree.degree1 <> converted_degree.degree2 THEN
                                    CASE  
                                        WHEN is_active = 'Y' THEN degree_map2.Degree 
                                        WHEN is_active IS NULL THEN  degree_map2_i.sgbstdn_degc_code_1
                                    END
                        END AS degc_code_2,

                        CASE 
                                WHEN converted_degree.degree1 <> converted_degree.degree2 THEN
                                    CASE 
                                        WHEN is_active = 'Y' THEN degree_map2.sgbstdn_majr_code_1 
                                        WHEN is_active IS NULL THEN  converted_degree.major_2
                                    END     
                        END AS majr_code_2,


                        ''AS majr_code_minr_2,
                        '' AS majr_code_minr_2_2,

                        CASE
                            wHEN agg_major_1 IS NULL THEN NULL 
                            WHEN is_active = 'Y' THEN
                                CASE WHEN converted_degree.degree1 <> converted_degree.degree2 THEN degree_map2.sgbstdn_majr_code_conc_1 END 
                        END AS majr_code_conc_2,


                        '' AS majr_code_conc_2_2,
                        '' AS majr_code_conc_2_3,


                        CASE
                            WHEN converted_degree.degree1 = converted_degree.degree2 THEN
                                    CASE
                                        WHEN is_active = 'Y' THEN degree_map2.sgbstdn_majr_code_1 
                                        WHEN is_active IS NULL THEN converted_degree.major_2
                                        
                                    END 
                        END AS  sgbstdn_majr_code_1_2,


                        CASE 

                                WHEN is_active = 'Y' THEN degree_map1.Program
                                WHEN is_active IS NuLL THEN degree_map1_i.sgbstdn_program_1

                        END AS sgbstdn_program_1,



                        CASE
                            wHEN agg_major_1 IS NULL THEN NULL 
                            WHEN is_active = 'Y' THEN 
                                CASE WHEN converted_degree.degree1 <> converted_degree.degree2 THEN degree_map2.Program END 
                                ELSE degree_map2_i.sgbstdn_program_1
                        END AS sgbstdn_program_2



        FROM

                styp  
                LEFT JOIN count_degree ON styp.sac_id = count_degree.id_num AND styp.term_code_eff = count_degree.sudo_term
                LEFT JOIN converted_degree ON styp.sac_id = converted_degree.id_num ANd styp.term_code_eff = converted_degree.sudo_term 
                LEFT JOIN converted_cert ON styp.sac_id = converted_cert.id_num ANd styp.term_code_eff = converted_cert.sudo_term 
                LEFT JOIN banner_degree_map AS degree_map1 ON converted_degree.degree_map1 = degree_map1.map_code
                LEFT JOIN banner_degree_map AS degree_map2 ON converted_degree.degree_map2 = degree_map2.map_code
                LEFT JOIN banner_degree_map AS cert_map1 ON converted_cert.cert_map1 = cert_map1.map_code
                LEFT JOIN banner_degree_map AS cert_map2 ON converted_cert.cert_map2 = cert_map2.map_code

                LEFT JOIN banner_degree_map_inactive AS degree_map1_i ON converted_degree.degree1 = degree_map1_i.j1_degree
                LEFT JOIN banner_degree_map_inactive AS degree_map2_i ON converted_degree.degree2 = degree_map2_i.j1_degree
                LEFT JOIN banner_degree_map_inactive AS cert_map1_i ON converted_cert.cert1_degr_cde = cert_map1_i.j1_degree
                LEFT JOIN banner_degree_map_inactive AS cert_map2_i ON converted_cert.cert_2_degr_cde = cert_map2_i.j1_degree



        
        
),
filled_first_degree_map AS 
(
        SELECT 

                hist_group,
                ft_pt_ind,
                load_p_f,
                candidacy_type,
                is_transfer,
                is_first_term,
                agg_major_1,
                agg_major_2,
                agg_concentration_1,
                agg_degree_code,
                agg_sig_desc,
                agg_reason_code,
                start_hist,
                start_term,
                ini_styp,
                row_num,
                count_row,
                is_active,
                sac_id,
                term_code_eff,
                stst_code,
                levl_code,
                styp_code,
                term_code_matric,
                term_code_admit,
                exp_grad_date,
                camp_code,
                full_part_ind,
                sess_code,
                resd_code,

                CASE 
                    WHEN coll_code_1 IS NULL and row_num = 1 THEN 'U'
                    ELSE coll_code_1
                END AS coll_code_1,

                CASE 
                    WHEN coll_code_1 IS NULL and row_num = 1 THEN 'NOND'
                    ELSE degc_code_1  
                END AS degc_code_1,

                CASE 
                    WHEN majr_code_1 IS NOT NULL THEN majr_code_1
                    WHEN coll_code_1 IS NULL and row_num = 1 THEN 'ATLG' 
                    ELSE majr_code_1  
                END AS majr_code_1,

                majr_code_minr_1,
                majr_code_minr_1_2,
                majr_code_conc_1,
                majr_code_conc_1_2,
                majr_code_conc_1_3,
                coll_code_2,
                degc_code_2,
                majr_code_2,
                majr_code_minr_2,
                majr_code_minr_2_2,
                majr_code_conc_2,
                majr_code_conc_2_2,
                majr_code_conc_2_3,
                sgbstdn_majr_code_1_2,

                CASE 
                    wHEN agg_major_1 IS NULL THEN NULL
                    WHEN coll_code_1 IS NULL and row_num = 1 THEN 'NOND' 
                    ELSE sgbstdn_program_1
                END AS sgbstdn_program_1,

                sgbstdn_program_2

        FROM 

                mapped_degree
),


filled_down_mapped_degree AS 

(

SELECT 
        hist_group,
        ft_pt_ind,
        load_p_f,
        candidacy_type,
        is_transfer,
        is_first_term,
        agg_major_1,
        agg_major_2,
        agg_concentration_1,
        agg_degree_code,
        agg_sig_desc,
        agg_reason_code,
        start_hist,
        start_term,
        ini_styp,
        t1.row_num,
        count_row,
        is_active,
        t1.sac_id,
        term_code_eff,
        stst_code,
        levl_code,
        styp_code,
        term_code_matric,
        term_code_admit,
        exp_grad_date,
        camp_code,
        full_part_ind,
        sess_code,
        resd_code,

        COALESCE(
            coll_code_1,
            COALESCE(
                LAG(coll_code_1, 1) OVER (PARTITION BY sac_id ORDER BY term_code_eff),
                COALESCE(
                    LAG(coll_code_1, 2) OVER (PARTITION BY sac_id ORDER BY term_code_eff),
                    COALESCE(
                        LAG(coll_code_1, 3) OVER (PARTITION BY sac_id ORDER BY term_code_eff),
                        COALESCE(
                            LAG(coll_code_1, 4) OVER (PARTITION BY sac_id ORDER BY term_code_eff),
                            COALESCE(
                                LAG(coll_code_1, 5) OVER (PARTITION BY sac_id ORDER BY term_code_eff),
                                LAG(coll_code_1, 6) OVER (PARTITION BY sac_id ORDER BY term_code_eff)
                            )
                        )
                    )
                )
            )
        ) AS coll_code_1,
        COALESCE(
            degc_code_1,
            COALESCE(
                LAG(degc_code_1, 1) OVER (PARTITION BY sac_id ORDER BY term_code_eff),
                COALESCE(
                    LAG(degc_code_1, 2) OVER (PARTITION BY sac_id ORDER BY term_code_eff),
                    COALESCE(
                        LAG(degc_code_1, 3) OVER (PARTITION BY sac_id ORDER BY term_code_eff),
                        COALESCE(
                            LAG(degc_code_1, 4) OVER (PARTITION BY sac_id ORDER BY term_code_eff),
                            COALESCE(
                                LAG(degc_code_1, 5) OVER (PARTITION BY sac_id ORDER BY term_code_eff),
                                LAG(degc_code_1, 6) OVER (PARTITION BY sac_id ORDER BY term_code_eff)
                            )
                        )
                    )
                )
            )
        ) AS degc_code_1,

    COALESCE(
        majr_code_1,
        COALESCE(
            LAG(majr_code_1, 1) OVER (PARTITION BY sac_id ORDER BY term_code_eff),
            COALESCE(
                LAG(majr_code_1, 2) OVER (PARTITION BY sac_id ORDER BY term_code_eff),
                COALESCE(
                    LAG(majr_code_1, 3) OVER (PARTITION BY sac_id ORDER BY term_code_eff),
                    COALESCE(
                        LAG(majr_code_1, 4) OVER (PARTITION BY sac_id ORDER BY term_code_eff),
                        COALESCE(
                            LAG(majr_code_1, 5) OVER (PARTITION BY sac_id ORDER BY term_code_eff),
                            LAG(majr_code_1, 6) OVER (PARTITION BY sac_id ORDER BY term_code_eff)
                        )
                    )
                )
            )
        )
    ) AS majr_code_1,


        majr_code_minr_1,
        majr_code_minr_1_2,

COALESCE(
    majr_code_conc_1,
    COALESCE(
        LAG(majr_code_conc_1, 1) OVER (PARTITION BY sac_id ORDER BY term_code_eff),
        COALESCE(
            LAG(majr_code_conc_1, 2) OVER (PARTITION BY sac_id ORDER BY term_code_eff),
            COALESCE(
                LAG(majr_code_conc_1, 3) OVER (PARTITION BY sac_id ORDER BY term_code_eff),
                COALESCE(
                    LAG(majr_code_conc_1, 4) OVER (PARTITION BY sac_id ORDER BY term_code_eff),
                    COALESCE(
                        LAG(majr_code_conc_1, 5) OVER (PARTITION BY sac_id ORDER BY term_code_eff),
                        LAG(majr_code_conc_1, 6) OVER (PARTITION BY sac_id ORDER BY term_code_eff)
                    )
                )
            )
        )
    )
) AS majr_code_conc_1,

        majr_code_conc_1_2,
        majr_code_conc_1_3,


COALESCE(
    coll_code_2,
    COALESCE(
        LAG(coll_code_2, 1) OVER (PARTITION BY sac_id ORDER BY term_code_eff),
        COALESCE(
            LAG(coll_code_2, 2) OVER (PARTITION BY sac_id ORDER BY term_code_eff),
            COALESCE(
                LAG(coll_code_2, 3) OVER (PARTITION BY sac_id ORDER BY term_code_eff),
                COALESCE(
                    LAG(coll_code_2, 4) OVER (PARTITION BY sac_id ORDER BY term_code_eff),
                    COALESCE(
                        LAG(coll_code_2, 5) OVER (PARTITION BY sac_id ORDER BY term_code_eff),
                        LAG(coll_code_2, 6) OVER (PARTITION BY sac_id ORDER BY term_code_eff)
                    )
                )
            )
        )
    )
) AS coll_code_2,

COALESCE(
    degc_code_2,
    COALESCE(
        LAG(degc_code_2, 1) OVER (PARTITION BY sac_id ORDER BY term_code_eff),
        COALESCE(
            LAG(degc_code_2, 2) OVER (PARTITION BY sac_id ORDER BY term_code_eff),
            COALESCE(
                LAG(degc_code_2, 3) OVER (PARTITION BY sac_id ORDER BY term_code_eff),
                COALESCE(
                    LAG(degc_code_2, 4) OVER (PARTITION BY sac_id ORDER BY term_code_eff),
                    COALESCE(
                        LAG(degc_code_2, 5) OVER (PARTITION BY sac_id ORDER BY term_code_eff),
                        LAG(degc_code_2, 6) OVER (PARTITION BY sac_id ORDER BY term_code_eff)
                    )
                )
            )
        )
    )
) AS degc_code_2,


COALESCE(
    majr_code_2,
    COALESCE(
        LAG(majr_code_2, 1) OVER (PARTITION BY sac_id ORDER BY term_code_eff),
        COALESCE(
            LAG(majr_code_2, 2) OVER (PARTITION BY sac_id ORDER BY term_code_eff),
            COALESCE(
                LAG(majr_code_2, 3) OVER (PARTITION BY sac_id ORDER BY term_code_eff),
                COALESCE(
                    LAG(majr_code_2, 4) OVER (PARTITION BY sac_id ORDER BY term_code_eff),
                    COALESCE(
                        LAG(majr_code_2, 5) OVER (PARTITION BY sac_id ORDER BY term_code_eff),
                        LAG(majr_code_2, 6) OVER (PARTITION BY sac_id ORDER BY term_code_eff)
                    )
                )
            )
        )
    )
) AS majr_code_2,



        majr_code_minr_2,
        majr_code_minr_2_2,
        majr_code_conc_2,
        majr_code_conc_2_2,
        majr_code_conc_2_3,
        sgbstdn_majr_code_1_2,

COALESCE(
    sgbstdn_program_1,
    COALESCE(
        LAG(sgbstdn_program_1, 1) OVER (PARTITION BY sac_id ORDER BY term_code_eff),
        COALESCE(
            LAG(sgbstdn_program_1, 2) OVER (PARTITION BY sac_id ORDER BY term_code_eff),
            COALESCE(
                LAG(sgbstdn_program_1, 3) OVER (PARTITION BY sac_id ORDER BY term_code_eff),
                COALESCE(
                    LAG(sgbstdn_program_1, 4) OVER (PARTITION BY sac_id ORDER BY term_code_eff),
                    COALESCE(
                        LAG(sgbstdn_program_1, 5) OVER (PARTITION BY sac_id ORDER BY term_code_eff),
                        LAG(sgbstdn_program_1, 6) OVER (PARTITION BY sac_id ORDER BY term_code_eff)
                    )
                )
            )
        )
    )
) AS sgbstdn_program_1,


COALESCE(
    sgbstdn_program_2,
    COALESCE(
        LAG(sgbstdn_program_2, 1) OVER (PARTITION BY sac_id ORDER BY term_code_eff),
        COALESCE(
            LAG(sgbstdn_program_2, 2) OVER (PARTITION BY sac_id ORDER BY term_code_eff),
            COALESCE(
                LAG(sgbstdn_program_2, 3) OVER (PARTITION BY sac_id ORDER BY term_code_eff),
                COALESCE(
                    LAG(sgbstdn_program_2, 4) OVER (PARTITION BY sac_id ORDER BY term_code_eff),
                    COALESCE(
                        LAG(sgbstdn_program_2, 5) OVER (PARTITION BY sac_id ORDER BY term_code_eff),
                        LAG(sgbstdn_program_2, 6) OVER (PARTITION BY sac_id ORDER BY term_code_eff)
                    )
                )
            )
        )
    )
) AS sgbstdn_program_2


FROM 
        filled_first_degree_map AS t1

),  

term_list AS 
(
        SELECT DISTINCT 
                term_code_eff
        FROM 
                filled_down_mapped_degree
),

term_with_next AS (
  SELECT 
    term_code_eff,
    LEAD(term_code_eff) OVER (ORDER BY term_code_eff) AS next_term_code_eff
  FROM term_list
)

SELECT 
/*
        hist_group,
        ft_pt_ind,
        load_p_f,
        candidacy_type,
        is_transfer,
        is_first_term,
        agg_major_1,
        agg_major_2,
        agg_concentration_1,
        agg_degree_code,
        agg_sig_desc,
        agg_reason_code,
        start_hist,
        start_term,
        ini_styp,
        row_num,
        count_row,
        is_active,
        sac_id,
        id_pidm_ban_id.spriden_id,*/
        /*******************************************/

        id_pidm_ban_id.spriden_pidm AS sgbstdn_pidm,

        CASE 
                WHEN term_code_eff % 100 = 6 THEN term_code_eff - 1 
                ELSE term_code_eff 
        END AS sgbstdn_term_code_eff,

        stst_code AS sgbstdn_stst_code,
        levl_code AS sgbstdn_levl_code,
        styp_code AS sgbstdn_styp_code,
        term_code_matric AS sgbstdn_term_code_matric,

        CASE 
                WHEN term_code_admit % 100 = 6 THEN term_code_admit - 1 
                ELSE term_code_admit 
        END AS sgbstdn_term_code_admit,

        exp_grad_date AS sgbstdn_exp_grad_date,
        camp_code AS sgbstdn_camp_code,
        full_part_ind AS sgbstdn_full_part_ind,
        sess_code AS sgbstdn_sess_code,
        resd_code AS sgbstdn_resd_code,
        coll_code_1 AS sgbstdn_coll_code_1,
        degc_code_1 AS sgbstdn_degc_code_1,
        majr_code_1 AS sgbstdn_majr_code_1,
        majr_code_minr_1 AS sgbstdn_majr_code_minr_1,
        majr_code_minr_1_2 AS sgbstdn_majr_code_minr_1_2,
        majr_code_conc_1 AS sgbstdn_majr_code_conc_1,
        majr_code_conc_1_2 AS sgbstdn_majr_code_conc_1_2,
        majr_code_conc_1_3 AS sgbstdn_majr_code_conc_1_3,
        coll_code_2 AS sgbstdn_coll_code_2,
        degc_code_2 AS sgbstdn_degc_code_2,
        majr_code_2 AS sgbstdn_majr_code_2,
        majr_code_minr_2 AS sgbstdn_majr_code_minr_2,
        majr_code_minr_2_2 AS sgbstdn_majr_code_minr_2_2,
        majr_code_conc_2 AS sgbstdn_majr_code_conc_2,
        majr_code_conc_2_2 AS sgbstdn_majr_code_conc_2_2,
        majr_code_conc_2_3 AS sgbstdn_majr_code_conc_2_3,
        '' AS sgbstdn_orsn_code,
        '' AS sgbstdn_prac_code,
        '' AS sgbstdn_advr_pidm,
        '' AS sgbstdn_grad_credit_appr_ind,
        '' AS sgbstdn_capl_code,
        '' AS sgbstdn_leav_code,
        '' AS sgbstdn_leav_from_date,
        '' AS sgbstdn_leav_to_date,
        '' AS sgbstdn_astd_code,
        '' AS sgbstdn_term_code_astd,
        '' AS sgbstdn_rate_code,
        '' AS sgbstdn_activity_date,
        sgbstdn_majr_code_1_2,
        '' AS sgbstdn_majr_code_2_2,
        '' AS sgbstdn_edlv_code,
        '' AS sgbstdn_incm_code,
        'ST' AS sgbstdn_admt_code,
        '' AS sgbstdn_emex_code,
        '' AS sgbstdn_aprn_code,
        '' AS sgbstdn_trcn_code,
        '' AS sgbstdn_gain_code,
        '' AS sgbstdn_voed_code,
        '' AS sgbstdn_blck_code,
        '' AS sgbstdn_term_code_grad,
        '' AS sgbstdn_acyr_code,
        '' AS sgbstdn_dept_code,
        '' AS sgbstdn_site_code,
        '' AS sgbstdn_dept_code_2,
        '' AS sgbstdn_egol_code,
        '' AS sgbstdn_degc_code_dual,
        '' AS sgbstdn_levl_code_dual,
        '' AS sgbstdn_dept_code_dual,
        '' AS sgbstdn_coll_code_dual,
        '' AS sgbstdn_majr_code_dual,
        '' AS sgbstdn_bskl_code,
        '' AS sgbstdn_prim_roll_ind,
        sgbstdn_program_1,

        CASE 
                WHEN term_code_admit % 100 = 6 THEN term_code_admit - 1 
                ELSE term_code_admit 
        END AS sgbstdn_term_code_ctlg_1,



        '' AS sgbstdn_dept_code_1_2,
        '' AS sgbstdn_majr_code_conc_121,
        '' AS sgbstdn_majr_code_conc_122,
        '' AS sgbstdn_majr_code_conc_123,
        '' AS sgbstdn_secd_roll_ind,
        '' AS sgbstdn_term_code_admit_2,
        '' AS sgbstdn_admt_code_2,
        sgbstdn_program_2,

        CASE 
                WHEN sgbstdn_program_2 IS NOT NULL 
                        THEN CASE 
                                WHEN term_code_admit % 100 = 6 THEN term_code_admit - 1
                                ELSE term_code_admit
                        END
        END AS sgbstdn_term_code_ctlg_2,

        '' AS sgbstdn_levl_code_2,
        '' AS sgbstdn_camp_code_2,
        '' AS sgbstdn_dept_code_2_2,
        '' AS sgbstdn_majr_code_conc_221,
        '' AS sgbstdn_majr_code_conc_222,
        '' AS sgbstdn_majr_code_conc_223,
        '' AS sgbstdn_curr_rule_1,
        '' AS sgbstdn_cmjr_rule_1_1,
        '' AS sgbstdn_ccon_rule_11_1,
        '' AS sgbstdn_ccon_rule_11_2,
        '' AS sgbstdn_ccon_rule_11_3,
        '' AS sgbstdn_cmjr_rule_1_2,
        '' AS sgbstdn_ccon_rule_12_1,
        '' AS sgbstdn_ccon_rule_12_2,
        '' AS sgbstdn_ccon_rule_12_3,
        '' AS sgbstdn_cmnr_rule_1_1,
        '' AS sgbstdn_cmnr_rule_1_2,
        '' AS sgbstdn_curr_rule_2,
        '' AS sgbstdn_cmjr_rule_2_1,
        '' AS sgbstdn_ccon_rule_21_1,
        '' AS sgbstdn_ccon_rule_21_2,
        '' AS sgbstdn_ccon_rule_21_3,
        '' AS sgbstdn_cmjr_rule_2_2,
        '' AS sgbstdn_ccon_rule_22_1,
        '' AS sgbstdn_ccon_rule_22_2,
        '' AS sgbstdn_ccon_rule_22_3,
        '' AS sgbstdn_cmnr_rule_2_1,
        '' AS sgbstdn_cmnr_rule_2_2,
        '' AS sgbstdn_prev_code,
        '' AS sgbstdn_term_code_prev,
        '' AS sgbstdn_cast_code,
        '' AS sgbstdn_term_code_cast,
        '' AS sgbstdn_data_origin,
        '' AS sgbstdn_user_id,
        '' AS sgbstdn_scpc_code,
        '' AS sgbstdn_surrogate_id,
        '' AS sgbstdn_version,
        '' AS sgbstdn_vpdi_code,
        '' AS sgbstdn_guid,
        1 AS sort
        


FROM 

        filled_down_mapped_degree
-- ====================================================================================
-- Join with temp table: ID_PIDM_BAN_ID
-- Purpose:
--   This temporary mapping table was imported into Jenzabar to match SAC student IDs
--   (from Jenzabar) with corresponding Banner PIDMs.
--
--   - GORADID_ADDITIONAL_ID = SAC ID (Jenzabar)
--   - spriden_pidm = Banner PIDM (primary key in Banner)
--
--   Required to populate the Banner field `sgbstdn_pidm` correctly during migration.
-- ====================================================================================
        LEFT JOIN ID_PIDM_BAN_ID ON  GORADID_ADDITIONAL_ID = sac_id


UNION ALL



SELECT 
/*        hist_group,
        ft_pt_ind,
        load_p_f,
        candidacy_type,
        is_transfer,
        is_first_term,
        agg_major_1,
        agg_major_2,
        agg_concentration_1,
        agg_degree_code,
        agg_sig_desc,
        agg_reason_code,
        start_hist,
        start_term,
        ini_styp,
        row_num,
        count_row,
        is_active,

        sac_id,
        id_pidm_ban_id.spriden_id,*/
        /*******************************************/

        id_pidm_ban_id.spriden_pidm AS sgbstdn_pidm,
        CASE 
                WHEN ISNULL(term_with_next.next_term_code_eff, filled_down_mapped_degree.term_code_eff) % 100 = 6 
                                        THEN ISNULL(term_with_next.next_term_code_eff, filled_down_mapped_degree.term_code_eff) - 1
                ELSE ISNULL(term_with_next.next_term_code_eff, filled_down_mapped_degree.term_code_eff)
        END AS sgbstdn_term_code_eff,

        CASE WHEN filled_down_mapped_degree.term_code_eff < 202501 THEN 'IS' ELSE 'AS' END AS sgbstdn_stst_code,

        levl_code AS sgbstdn_levl_code,
        styp_code AS sgbstdn_styp_code,
        term_code_matric AS sgbstdn_term_code_matric,

        CASE 
                WHEN term_code_admit % 100 = 6 THEN term_code_admit - 1
                ELSE term_code_admit
        END AS sgbstdn_term_code_admit,


        exp_grad_date AS sgbstdn_exp_grad_date,
        camp_code AS sgbstdn_camp_code,
        full_part_ind AS sgbstdn_full_part_ind,
        sess_code AS sgbstdn_sess_code,
        resd_code AS sgbstdn_resd_code,
        coll_code_1 AS sgbstdn_coll_code_1,
        degc_code_1 AS sgbstdn_degc_code_1,
        majr_code_1 AS sgbstdn_majr_code_1,
        majr_code_minr_1 AS sgbstdn_majr_code_minr_1,
        majr_code_minr_1_2 AS sgbstdn_majr_code_minr_1_2,
        majr_code_conc_1 AS sgbstdn_majr_code_conc_1,
        majr_code_conc_1_2 AS sgbstdn_majr_code_conc_1_2,
        majr_code_conc_1_3 AS sgbstdn_majr_code_conc_1_3,
        coll_code_2 AS sgbstdn_coll_code_2,
        degc_code_2 AS sgbstdn_degc_code_2,
        majr_code_2 AS sgbstdn_majr_code_2,
        majr_code_minr_2 AS sgbstdn_majr_code_minr_2,
        majr_code_minr_2_2 AS sgbstdn_majr_code_minr_2_2,
        majr_code_conc_2 AS sgbstdn_majr_code_conc_2,
        majr_code_conc_2_2 AS sgbstdn_majr_code_conc_2_2,
        majr_code_conc_2_3 AS sgbstdn_majr_code_conc_2_3,
        '' AS sgbstdn_orsn_code,
        '' AS sgbstdn_prac_code,
        '' AS sgbstdn_advr_pidm,
        '' AS sgbstdn_grad_credit_appr_ind,
        '' AS sgbstdn_capl_code,
        '' AS sgbstdn_leav_code,
        '' AS sgbstdn_leav_from_date,
        '' AS sgbstdn_leav_to_date,
        '' AS sgbstdn_astd_code,
        '' AS sgbstdn_term_code_astd,
        '' AS sgbstdn_rate_code,
        '' AS sgbstdn_activity_date,
        sgbstdn_majr_code_1_2,
        '' AS sgbstdn_majr_code_2_2,
        '' AS sgbstdn_edlv_code,
        '' AS sgbstdn_incm_code,
        'ST' AS sgbstdn_admt_code,
        '' AS sgbstdn_emex_code,
        '' AS sgbstdn_aprn_code,
        '' AS sgbstdn_trcn_code,
        '' AS sgbstdn_gain_code,
        '' AS sgbstdn_voed_code,
        '' AS sgbstdn_blck_code,
        '' AS sgbstdn_term_code_grad,
        '' AS sgbstdn_acyr_code,
        '' AS sgbstdn_dept_code,
        '' AS sgbstdn_site_code,
        '' AS sgbstdn_dept_code_2,
        '' AS sgbstdn_egol_code,
        '' AS sgbstdn_degc_code_dual,
        '' AS sgbstdn_levl_code_dual,
        '' AS sgbstdn_dept_code_dual,
        '' AS sgbstdn_coll_code_dual,
        '' AS sgbstdn_majr_code_dual,
        '' AS sgbstdn_bskl_code,
        '' AS sgbstdn_prim_roll_ind,
        sgbstdn_program_1,

        CASE 
                WHEN term_code_admit % 100 = 6 THEN term_code_admit - 1
                ELSE term_code_admit
        END AS sgbstdn_term_code_ctlg_1,


        '' AS sgbstdn_dept_code_1_2,
        '' AS sgbstdn_majr_code_conc_121,
        '' AS sgbstdn_majr_code_conc_122,
        '' AS sgbstdn_majr_code_conc_123,
        '' AS sgbstdn_secd_roll_ind,
        '' AS sgbstdn_term_code_admit_2,
        '' AS sgbstdn_admt_code_2,
        sgbstdn_program_2,

        CASE 
                WHEN sgbstdn_program_2 IS NOT NULL THEN 
                        CASE 
                                WHEN term_code_admit % 100 = 6 THEN term_code_admit - 1
                                ELSE term_code_admit
                        END
        END AS sgbstdn_term_code_ctlg_2,

        '' AS sgbstdn_levl_code_2,
        '' AS sgbstdn_camp_code_2,
        '' AS sgbstdn_dept_code_2_2,
        '' AS sgbstdn_majr_code_conc_221,
        '' AS sgbstdn_majr_code_conc_222,
        '' AS sgbstdn_majr_code_conc_223,
        '' AS sgbstdn_curr_rule_1,
        '' AS sgbstdn_cmjr_rule_1_1,
        '' AS sgbstdn_ccon_rule_11_1,
        '' AS sgbstdn_ccon_rule_11_2,
        '' AS sgbstdn_ccon_rule_11_3,
        '' AS sgbstdn_cmjr_rule_1_2,
        '' AS sgbstdn_ccon_rule_12_1,
        '' AS sgbstdn_ccon_rule_12_2,
        '' AS sgbstdn_ccon_rule_12_3,
        '' AS sgbstdn_cmnr_rule_1_1,
        '' AS sgbstdn_cmnr_rule_1_2,
        '' AS sgbstdn_curr_rule_2,
        '' AS sgbstdn_cmjr_rule_2_1,
        '' AS sgbstdn_ccon_rule_21_1,
        '' AS sgbstdn_ccon_rule_21_2,
        '' AS sgbstdn_ccon_rule_21_3,
        '' AS sgbstdn_cmjr_rule_2_2,
        '' AS sgbstdn_ccon_rule_22_1,
        '' AS sgbstdn_ccon_rule_22_2,
        '' AS sgbstdn_ccon_rule_22_3,
        '' AS sgbstdn_cmnr_rule_2_1,
        '' AS sgbstdn_cmnr_rule_2_2,
        '' AS sgbstdn_prev_code,
        '' AS sgbstdn_term_code_prev,
        '' AS sgbstdn_cast_code,
        '' AS sgbstdn_term_code_cast,
        '' AS sgbstdn_data_origin,
        '' AS sgbstdn_user_id,
        '' AS sgbstdn_scpc_code,
        '' AS sgbstdn_surrogate_id,
        '' AS sgbstdn_version,
        '' AS sgbstdn_vpdi_code,
        '' AS sgbstdn_guid,
        2 AS sort

FROM 
        filled_down_mapped_degree
        LEFT JOIN term_with_next ON filled_down_mapped_degree.term_code_eff = term_with_next.term_code_eff
        LEFT JOIN ID_PIDM_BAN_ID ON  GORADID_ADDITIONAL_ID= sac_id

WHERE 
        count_row = 1

 


ORDER BY   
        sgbstdn_pidm , sgbstdn_term_code_eff ,sort
