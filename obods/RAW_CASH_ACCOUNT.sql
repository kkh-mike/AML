

/*
核心業務目的為：
從核心存款帳戶主檔（WBS_DEP_FN_ACCT_MSTR）中撈取活存/現金帳戶資料，
排除內部過渡/特定科目帳號（74%），
並轉換為標準帳戶介面格式（常見於 AML 洗錢防制、資料倉儲或下游客戶帳戶預載檔）。
*/


/*
重點業務邏輯整理：
帳號標準化 (ACCT_NO + '000')：

核心存款帳號通常為 11 或 13 碼，此處統一在尾端補 '000'，是銀行系統常見的「主帳號 + 幣別/子序號」標準格式。

狀態定義 (ACCOUNT_STATUS)：

核心狀態 ACCT_STS = 'A' 代表正常戶，轉換為 '0'；其餘（如結清、凍結、警示等）統一轉換為 '1'。

科目過濾 (NOT LIKE '74%')：

排除非一般客戶的內部帳戶，確保只有真正的客戶實體/活期存款帳戶被載入監控或中台系統。

與前兩支程式的關聯性：

與稍早的 [LOAN_LIMIT]（放款帳戶介面）、[Preload_Customer]（客戶檔介面）屬於同一個體系，
都是將 WBS 核心資料清洗為特定中台/洗錢防制（AML）系統所需標準版面的 ETL View。

*/



USE [MYDB]
GO

/****** Object:  View [dbo].[RAW_CASH_ACCOUNT]    Script Date: 2026/9/11 下午 05:39:19 ******/
SET ANSI_NULLS ON
GO

SET QUOTED_IDENTIFIER ON
GO

-- 修改現金/存款帳戶原始資料檢視表
ALTER VIEW [dbo].[RAW_CASH_ACCOUNT] AS 

    SELECT 
        -- 帳號：存款主帳號後方補固定碼 '000'（配合下遊標準帳號 14~16 碼規格）
        ACCT_NO + '000' AS ACCOUNT_NBR,
        
        -- 應用系統別代碼：固定為 'SAV' (Savings 儲蓄/活存帳戶)
        'SAV' AS APPLICATION_CODE,
        
        -- 客戶統一編號 / CIF ID
        CUST_ID AS CUSTOMER_ID,
        
        -- 開戶/帳務分行代號：左側補 '0' 至 4 碼 (例如分行 '25' 轉為 '0025')
        REPLICATE('0', 4 - LEN(exs_brn)) + exs_brn AS BRANCH_NBR,
        
        -- 以下為保留/介面固定留空欄位
        '' AS BRANCH_NAME,
        '' AS ACCOUNT_TYPE_CODE,
        '' AS ACCOUNT_TYPE_DESC, 
        '' AS OFFICER_NBR,             -- 經辦/客戶經理工號
        '' AS OFFICER_NAME,            -- 經辦姓名
        '' AS CURRENT_BALANCE,         -- 目前帳面餘額
        '' AS AVAILABLE_BALANCE,       -- 可用餘額
        
        -- 開戶日期 (YYYYMMDD)
        ACCT_MSTR.OPN_ACCT_DT AS OPENING_DATE,
        
        -- 結清日期 (留空)
        '' AS CLOSED_DATE,
        
        -- 帳戶狀態轉碼：
        -- 若為 'A' (Active 正常) 轉為 '0' (有效/正常)；其餘非正常狀態轉為 '1' (非正常/凍結/結清)
        CASE WHEN ACCT_STS = 'A' THEN '0' ELSE '1' END AS ACCOUNT_STATUS,
        
        -- 透支額度 (留空)
        '' AS OVERDRAFT_LIMIT, 
        
        -- 最後異動/建檔日期：取該筆帳戶資料建立日 (CRTE_DT)
        ACCT_MSTR.CRTE_DT AS DATE_OF_LAST_ACTIVITY,
        
        -- 以下為標準介面預留代碼欄位 (留空)
        '' AS OPENING_METHOD_CODE,
        '' AS OPENING_METHOD_DESC, 
        '' AS PRODUCT_CODE,
        '' AS PRODUCT_DESC, 
        '' AS ACCOUNT_PURPOSE_CODE,
        '' AS ACCOUNT_PURPOSE_DESC,
        '' AS CORE_SYSTEM,             -- 核心系統代碼 (此處未填值)
        
        -- 批次資料處理基準日：固定取系統前一日日期 (Yesterday, 格式 YYYYMMDD)
        CONVERT(VARCHAR(8), DATEADD(D, -1, GETDATE()), 112) AS PROCESSING_DATE
    
        /* 註解保留欄位（可選 AML 相關標記）：
        ,'' AS SAR_EXCLUDE_FLAG        -- 可疑交易報告 (SAR) 排除標記
        ,'' AS TRANSFER_FLAG           -- 轉帳標記
        */
    
    -- 資料來源：存款金融帳戶主檔 (Deposit Financial Account Master)
    FROM WBS_DEP_FN_ACCT_MSTR ACCT_MSTR
    
    -- 排除條件：排除帳號開頭為 '74' 的帳號
    -- （'74%' 通常為銀行內部暫記、聯行往來、同業存匯或內部過渡虛擬科目帳號，非一般客戶存款帳戶）
    WHERE ACCT_MSTR.ACCT_NO NOT LIKE '74%'

GO
