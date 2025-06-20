# Jenzabar to Banner SGBSTDN T-SQL Conversion

This project provides a T-SQL script that transforms student enrollment and degree history data from the **Jenzabar SIS** into the **SGBSTDN format** required by **Ellucian Banner**. It is designed for institutions migrating or integrating systems where data structure and expectations differ significantly.

---

## 🎯 Purpose

In Jenzabar, student academic records (such as degree milestones) are often stored in **rows** across time—each row marking an event such as "entry", "exit", or "graduation". Banner, by contrast, expects a **flattened column format** where one row per term summarizes all relevant data.

This script:

- 🧩 Converts **row-based data** into **columnar term records** matching Banner's `SGBSTDN` structure
- 🕒 Detects **significant term-based changes** in student academic status
- 🛠 Generates a timeline of **term-by-term records**, including majors, degrees, levels, and student types
- 🎓 Maps institutional codes to Banner’s required format using provided mapping tables

---

## 🧩 Key Features

- Constructs **pseudo-term codes** (`sudo_term`) based on term start dates to simulate Banner-style term codes (e.g., `202501`)
- Maps **entry, exit, degree conferred, withdrawal** dates to corresponding academic terms
- Dynamically determines:
  - `styp_code` (student type)
  - `stst_code` (enrollment status)
  - `levl_code` (level)
  - Major, degree, and concentration codes
- Includes logic to **infer programs and majors** using current and historical degree mappings



---

## 🗃 Requirements

- Microsoft SQL Server
- Access to Jenzabar database tables:
  - `student_crs_hist`, `degree_history`, `major_minor_def`, etc.
- Mapping tables:
  - `banner_degree_map`
  - `ID_PIDM_BAN_ID` (temporary table mapping SAC IDs to Banner PIDMs)

---

## 📌 Output Format

The final SELECT produces a dataset compatible with `SGBSTDN`, including fields like:

- `sgbstdn_pidm`, `sgbstdn_term_code_eff`
- `sgbstdn_styp_code`, `sgbstdn_stst_code`, `sgbstdn_levl_code`
- Major, minor, and concentration codes
- Dual degree/program support
- Term-based flattening for Banner ingestion

---

## 🧠 Author

**Nipit Pongpan**  
Application Specialist, St Augustine College at Lewis University
📍 Chicago, IL  

---

## 📜 License

This project is licensed under the MIT License.


---

## © Copyright

Created by **Nipit Pongpan**  
© 2025 Nipit Pongpan. All rights reserved.
