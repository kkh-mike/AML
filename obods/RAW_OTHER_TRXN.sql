

/*

這支 View (RAW_OTHER_TRXN) 是馬來西亞納閩分行核心系統（MYWBS）提供給洗錢防制系統（AML）的「其他交易標準介面檔（Other Transactions Interface）」。

核心目的與運作邏輯
資料範圍：整合並清洗銀行內的放款專用帳戶交易與特定會計科目交易，透過 UNION ALL 將兩種類型的交易標準化產出。

正負金額轉向：核心傳票檔（WBS_ACC_VOU_DTL_AML）通常以正負號代表借貸方；此 View 依據科目代號（CODE）與本金/利息金額（P_AMT / I_AMT）的正負號，將其拆解轉正為 AML 系統所需的轉入金額（AMOUNT_IN）與轉出金額（AMOUNT_OUT）。

排除機制：

排除已存在於電匯交易檔（RAW_WIRE_TRXN）的交易，避免重複監控。

排除放款開戶/撥款（029000）與匯出匯款建檔（150000）等特定功能代碼。

通路識別：若經辦代號（AGENT_ID）為 'B2BOP'，識別為網銀交易（代碼 4）；否則視為臨櫃交易（代碼 3）。
*/


/*


*/



USE [MYDB]
GO

/****** Object:  View [dbo].[RAW_OTHER_TRXN]    Script Date: 2026/9/11 下午 05:39:44 ******/
SET ANSI_NULLS ON
GO

SET QUOTED_IDENTIFIER ON
GO

/*  
 * 【程式功能】納閩分行洗錢防制系統 (AML) - 其他交易每日批次來源資料檔 (Other Transactions)
 * 【主要來源表】
 *   - WBS_ACC_VOU_DTL_AML : 會計傳票交易明細檔 (AML 專用)
 *   - WBS_RAA_FUNC_INFO   : 系統交易功能代碼對照表
 *   - WBS_LN_FN_ACCT      : 放款融資帳戶主檔
 *   - RAW_WIRE_TRXN       : 電匯交易介面檔 (用於排除重複交易)
 * 【版本修訂紀錄】
 *   - 20200918 : 納閩分行洗錢防制系統建置
 *   - 20220114 : AML 本位幣由 MYR 改為 USD
 *   - 20221020 : 排除功能代碼 029000 (Loan Creation)、150000 (Outward Remittance Creation)
 */
ALTER VIEW [dbo].[RAW_OTHER_TRXN] AS 

    /* =========================================================================
       區塊一：放款融資類帳戶交易 (Loan / Financing Account Transactions)
       ========================================================================= */
    SELECT 
        A.TRANSACTION_ID                        -- 交易流水號 / 唯一識別碼
        ,A.CUSTOMER_ID                          -- 客戶統一編號 / 客戶代碼
        ,A.REFNO AS ACCOUNT_NBR                 -- 交易帳號 (放款帳號+序號)
        
        -- 業務模組識別：放款或利息科目歸類為放款類 (LNA)，其餘歸類為活儲存款類 (SAV)
        ,IIF(A.CODE LIKE '13%' OR A.CODE LIKE '2252%' OR A.CODE LIKE '1151%', 'LNA', 'SAV') AS APPLICATION_CODE
        
        -- 轉入金額 (AMOUNT_IN)：將來源為負數之扣借記金額轉為正數呈現
        ,CAST(CASE 
            WHEN A.CODE LIKE '13%' AND A.P_AMT < 0 THEN A.P_AMT * -1                                       -- 放款本金貸記/減少
            WHEN (A.CODE LIKE '1151%' AND A.I_AMT < 0) OR (A.CODE LIKE '2252%' AND A.I_AMT < 0) THEN A.I_AMT * -1 -- 利息科目負項轉正
            WHEN SUBSTRING(A.CODE, 1, 4) IN ('2317', '2327', '2545') AND A.P_AMT < 0 THEN A.P_AMT * -1    -- 特定往來科目負項轉正
            ELSE 0 
         END AS VARCHAR) AS AMOUNT_IN
        
        -- 轉出金額 (AMOUNT_OUT)：取來源為正數之金額
        ,CAST(CASE 
            WHEN A.CODE LIKE '13%' AND A.P_AMT > 0 THEN A.P_AMT                                           -- 放款本金借記/增加
            WHEN SUBSTRING(A.CODE, 1, 4) IN ('2317', '2327', '2545') AND A.P_AMT > 0 THEN A.P_AMT        -- 特定往來科目借記
            WHEN A.CODE LIKE '2151%' AND A.I_AMT > 0 THEN A.I_AMT                                         -- 特定利息支出
            ELSE 0 
         END AS VARCHAR) AS AMOUNT_OUT
        
        ,A.FUNC_CODE AS TRANSACTION_CODE        -- 交易功能代號
        ,B.FUNC_NAME AS TRANSACTION_DESC        -- 交易功能名稱 (關聯 WBS_RAA_FUNC_INFO)
        ,'' AS TELLER_ID                        -- 櫃員代號 (介面保留，固定給空值)
        
        -- 交易管道代碼：B2BOP 為企業網銀 ('4')，其餘視為臨櫃交易 ('3')
        ,IIF(A.AGENT_ID = 'B2BOP', '4', '3') AS TELLER_TYPE
        ,IIF(A.AGENT_ID = 'B2BOP', 'Internet banking', 'Branch Teller') AS TELLER_TYPE_DESC
        
        ,A.TRADE_DATE AS TRANSACTION_DATE       -- 交易執行日期 (YYYYMMDD)
        ,'' AS CASHED_CHECK_FLAG                -- 是否兌現支票 (介面保留)
        ,'' AS CHECK_NBR                        -- 支票號碼 (介面保留)
        ,'' AS CURRENCY_CODE                    -- 交易幣別 (介面保留)
        ,'' AS ORI_AMOUNT_IN                    -- 原始轉入金額 (介面保留)
        ,'' AS ORI_AMOUNT_OUT                   -- 原始轉出金額 (介面保留)
        ,A.CUST_BRANCH AS BRANCH_OF_TRXN        -- 交易所屬分行代碼
        ,'MY' AS BANK_NBR                       -- 銀行國別代碼 (固定為馬來西亞 'MY')
        ,'MYWBS' AS CORE_SYSTEM                 -- 來源核心帳務系統識別
        ,CONVERT(VARCHAR(10), DATEADD(D, -1, GETDATE()), 20) AS PROCESSING_DATE -- 資料批次處理日 (取昨日 YYYY-MM-DD)
        ,'' AS CONDUCTOR_ID                     -- 實際交易代理人/代辦人身分證號 (介面保留)
    
    FROM WBS_ACC_VOU_DTL_AML A 
    LEFT JOIN WBS_RAA_FUNC_INFO B 
        ON A.FUNC_CODE = B.FUNC_CODE
    WHERE 
        -- 條件 1：帳號必須存在於放款帳戶主檔且科目為 '13%' (放款類)
        RTRIM(LTRIM(A.REFNO)) IN (
            SELECT Z.ACCT_NO + RTRIM(LTRIM(Z.SEQ_NO)) 
            FROM WBS_LN_FN_ACCT Z 
            WHERE Z.ACC_CD LIKE '13%'
        )
        -- 條件 2：排除 150000 (匯出匯款建檔，此類已由電匯介面處理)
        AND A.FUNC_CODE NOT IN ('150000')
        -- 條件 3：排除已納入電匯交易檔 (RAW_WIRE_TRXN) 的交易，避免重複監控
        AND A.REFNO NOT IN (SELECT TRANSACTION_ID FROM RAW_WIRE_TRXN)

    UNION ALL 

    /* =========================================================================
       區塊二：特定會計科目雜項交易 (Special Accounting Code Transactions)
       ========================================================================= */
    SELECT 
        G.TRANSACTION_ID                        -- 交易流水號
        ,G.CUSTOMER_ID                          -- 客戶統一編號
        ,G.REFNO AS ACCOUNT_NBR                 -- 交易參考帳號
        
        -- 業務模組識別 (LNA: 放款, SAV: 存款/儲蓄)
        ,CASE 
            WHEN G.CODE LIKE '13%' OR G.CODE LIKE '2252%' OR G.CODE LIKE '1151%' THEN 'LNA' 
            ELSE 'SAV' 
         END AS APPLICATION_CODE
        
        -- 轉入金額轉換 (負項轉正)
        ,CAST(CASE 
            WHEN G.CODE LIKE '13%' AND G.P_AMT < 0 THEN G.P_AMT * -1
            WHEN (G.CODE LIKE '1151%' AND G.I_AMT < 0) OR (G.CODE LIKE '2252%' AND G.I_AMT < 0) THEN G.I_AMT * -1
            WHEN SUBSTRING(G.CODE, 1, 4) IN ('2317', '2327', '2545') AND G.P_AMT < 0 THEN G.P_AMT * -1 
            ELSE 0 
         END AS VARCHAR) AS AMOUNT_IN
        
        -- 轉出金額轉換 (取正數)
        ,CAST(CASE 
            WHEN G.CODE LIKE '13%' AND G.P_AMT > 0 THEN G.P_AMT
            WHEN SUBSTRING(G.CODE, 1, 4) IN ('2317', '2327', '2545') AND G.P_AMT > 0 THEN G.P_AMT
            WHEN G.CODE LIKE '2151%' AND G.I_AMT > 0 THEN G.I_AMT
            ELSE 0 
         END AS VARCHAR) AS AMOUNT_OUT
        
        ,G.FUNC_CODE AS TRANSACTION_CODE        -- 交易功能代號
        ,H.FUNC_NAME AS TRANSACTION_DESC        -- 交易功能名稱
        ,'' AS TELLER_ID                        -- 櫃員代號
        
        -- 交易通路類型轉換
        ,CASE WHEN G.AGENT_ID = 'B2BOP' THEN '4' ELSE '3' END AS TELLER_TYPE
        ,CASE WHEN G.AGENT_ID = 'B2BOP' THEN 'Internet banking' ELSE 'Branch Teller' END AS TELLER_TYPE_DESC
        
        ,G.TRADE_DATE AS TRANSACTION_DATE       -- 交易日期
        ,'' AS CASHED_CHECK_FLAG
        ,'' AS CHECK_NBR 
        ,'' AS CURRENCY_CODE
        ,'' AS ORI_AMOUNT_IN
        ,'' AS ORI_AMOUNT_OUT
        ,G.CUST_BRANCH AS BRANCH_OF_TRXN        -- 分行代碼
        ,'MY' AS BANK_NBR                       -- 銀行國別
        ,'MYWBS' AS CORE_SYSTEM                 -- 核心系統
        ,CONVERT(VARCHAR(10), DATEADD(D, -1, GETDATE()), 20) AS PROCESSING_DATE
        ,'' AS CONDUCTOR_ID
    
    FROM WBS_ACC_VOU_DTL_AML G 
    LEFT JOIN WBS_RAA_FUNC_INFO H 
        ON G.FUNC_CODE = H.FUNC_CODE
    WHERE 
        -- 條件 1：鎖定特定資產負債/過渡科目 (如 2317、2327、2545)
        SUBSTRING(G.CODE, 1, 4) IN ('2317', '2327', '2545')
        -- 條件 2：排除放款建檔 (029000) 與匯出建檔 (150000)
        AND G.FUNC_CODE NOT IN ('029000', '150000')
        -- 條件 3：排除已存在電匯介面檔的記錄
        AND G.REFNO NOT IN (SELECT TRANSACTION_ID FROM RAW_WIRE_TRXN)
GO
