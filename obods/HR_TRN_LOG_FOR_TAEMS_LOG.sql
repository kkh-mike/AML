/*
業務用途：
將分散在各國/各地區資料庫（AUDB 澳洲、JPDB 日本、SGDB 新加坡、MYDB 本地庫）
的差勤打卡紀錄（HR_TRN_LOG），整合成一個單一入口檢視表，供差勤系統（TAEMS）統一查詢。
*/


USE [MYDB]
GO

/****** Object:  View [dbo].[HR_TRN_LOG_FOR_TAEMS_LOG]    Script Date: 2026/9/11 下午 05:38:04 ******/

-- 設定處理 NULL 值的 ANSI 標準（設為 ON 時，任何與 NULL 的比較運算結果皆為 UNKNOWN）
SET ANSI_NULLS ON
GO

-- 設定引號識別元的標準（設為 ON 時，雙引號 "" 會被視為物件名稱/識別元，而非字串文字）
SET QUOTED_IDENTIFIER ON
GO

-- 修改名為 [HR_TRN_LOG_FOR_TAEMS_LOG] 的 View
-- 用途：提供給 TAEMS 系統查詢整合後的出勤/打卡交易紀錄 (HR Transaction Log)
ALTER VIEW [dbo].[HR_TRN_LOG_FOR_TAEMS_LOG]
AS
    -- 1. 撈取澳洲 (AUDB) 的差勤交易紀錄
    SELECT * FROM AUDB.DBO.HR_TRN_LOG A

    UNION ALL -- 使用 UNION ALL 聯集資料（保留所有紀錄，不進行跨表去重以提高效能）

    -- 2. 撈取日本 (JPDB) 的差勤交易紀錄
    SELECT * FROM JPDB.DBO.HR_TRN_LOG A

    UNION ALL

    -- 3. 撈取新加坡 (SGDB) 的差勤交易紀錄
    SELECT * FROM SGDB.DBO.HR_TRN_LOG A

    UNION ALL

    -- 4. 撈取母庫/本庫 (MYDB) 的差勤交易紀錄
    SELECT * FROM MYDB.DBO.HR_TRN_LOG A

GO




/*
潛在維護風險（建議改善）：
若未來這四個資料庫中的 HR_TRN_LOG 
表結構有欄位順序或型態不一致（例如其中一個庫加了新欄位），
此 View 會發生欄位錯位或執行失敗。
*/
