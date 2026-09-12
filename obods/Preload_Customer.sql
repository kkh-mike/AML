

/*
核心業務目的為：從核心銀行系統（MYWBS）中整理「納閩分行（Branch: 0925）」的客戶基本資料（CIF）、KYC 與授信/存款往來狀態，並透過自訂業務邏輯重新歸類客戶形態（CIF_TYPE），最終轉換為 AML（反洗錢/防制洗錢）
監控系統所需的客戶基本資料預載介面規格（Preload Customer Layout）。
*/


/*

重點業務邏輯剖析：
AML 客群分類矩陣 (CIF_TYPE)：

透過是否有實質往來（存款帳號 WBS_DEP_ACC 正常、授信額度 WBS_FAC_INFO 有餘額）、是否為純擔保人、同業或特定業務類別（如代碼 00706），組合出 A1~F1 等分類代碼。

新戶寬限邏輯（B1_OPEN vs B1_CLOSE）：對於尚無實質存貸往來的一般客戶，若開戶日在近 7 天內會被視為活耀新開戶（B1_OPEN，狀態為 O），超過 7 天未往來則強制判定為關閉（B1_CLOSE，狀態為 C）。

客群切分（Segment_Code）：

ID（內部/過渡帳號）：如 A1、F1。

CB（商業銀行主要監控客群）：有實質額度/存款往來者（如 A2、B2、C2 等）。

NCR（無往來/非核心監控）：純保證人無額度、已停用或超過開戶期的帳戶。

特殊除外處理：

客戶代號 MY2199999 為內部掛帳虛擬 CIF，在此 View 中被強制改為 Record_Stat = 'C'（Close），避免觸發 AML 監控警示。


*/



USE [MYDB]
GO

/****** Object:  View [dbo].[Preload_Customer]    Script Date: 2026/9/11 下午 05:38:57 ******/
SET ANSI_NULLS ON
GO

SET QUOTED_IDENTIFIER ON
GO

/*
*   版本歷程註記：
*   20200918 納閩分行上線/客製邏輯
*   20211130 掛帳用虛擬CIF (MY2199999) 強制設定狀態為 CLOSE ('C')
*/
ALTER VIEW [dbo].[Preload_Customer] AS

    -- =========================================================================
    -- 1. CTE: CIF_TYPE - 分析客戶業務往來特徵並進行多維度客戶分類
    -- =========================================================================
    WITH CIF_TYPE AS (
        SELECT 
            CIF.CIF_CUST_INFO_SEQ
            -- 依據是否為保證人(GUR)、金融機構(FI)、特定行業代碼(00706/00717)、以及是否有存放款(DEP_OR_FAC)進行分類
            ,CASE 
                -- 一般企業/特定行業別 (00706)
                WHEN CIF.GUR<>'Y' AND CIF.FI<>'Y' AND CIF.AML_BUZ_SECTOR_CD='00706' AND CIF.DEP_OR_FAC<>'Y' THEN 'A1'
                WHEN CIF.GUR<>'Y' AND CIF.FI<>'Y' AND CIF.AML_BUZ_SECTOR_CD='00706' AND CIF.DEP_OR_FAC='Y'  THEN 'A2'
                
                -- 非 00706 且無存款/授信：7天內新開戶標記為 B1_OPEN，超過7天為 B1_CLOSE
                WHEN CIF.GUR<>'Y' AND CIF.FI<>'Y' AND CIF.AML_BUZ_SECTOR_CD<>'00706' AND CIF.DEP_OR_FAC<>'Y' THEN 
                    CASE WHEN CIF.AML_OPENING_DATE BETWEEN CONVERT(VARCHAR,GETDATE()-7,112) AND CONVERT(VARCHAR,GETDATE()-1,112) 
                         THEN 'B1_OPEN'
                         ELSE 'B1_CLOSE' 
                    END
                WHEN CIF.GUR<>'Y' AND CIF.FI<>'Y' AND CIF.AML_BUZ_SECTOR_CD<>'00706' AND CIF.DEP_OR_FAC='Y'  THEN 'B2'
                
                -- 金融同業客戶 (FI = 'Y')
                WHEN CIF.GUR<>'Y' AND CIF.FI='Y'  AND CIF.AML_BUZ_SECTOR_CD='00706' AND CIF.DEP_OR_FAC<>'Y' THEN 'C1'
                WHEN CIF.GUR<>'Y' AND CIF.FI<>'Y' AND CIF.AML_BUZ_SECTOR_CD='00706' AND CIF.DEP_OR_FAC='Y'  THEN 'C2'
                
                -- 純保證人客戶 (GUR = 'Y')
                WHEN CIF.GUR='Y'  AND CIF.FI<>'Y' AND CIF.AML_BUZ_SECTOR_CD<>'00706' AND CIF.DEP_OR_FAC<>'Y' THEN 'D1'
                WHEN CIF.GUR<>'Y' AND CIF.FI<>'Y' AND CIF.AML_BUZ_SECTOR_CD<>'00706' AND CIF.DEP_OR_FAC='Y'  THEN 'D2'
                WHEN CIF.GUR='Y'  AND CIF.FI<>'Y' AND CIF.AML_BUZ_SECTOR_CD='00706' AND CIF.DEP_OR_FAC<>'Y' THEN 'E1'
                WHEN CIF.GUR<>'Y' AND CIF.FI<>'Y' AND CIF.AML_BUZ_SECTOR_CD='00706' AND CIF.DEP_OR_FAC='Y'  THEN 'E2'
                
                -- 特定業務類別 (00717)
                WHEN CIF.AML_BUZ_SECTOR_CD='00717' THEN 'F1'
                ELSE 'ELSE' 
             END AS CIF_TYPE
            ,CIF.AML_BUZ_SECTOR_CD
            ,CIF.AML_OPENING_DATE
        FROM (
            SELECT
                CIF.CIF_CUST_INFO_SEQ
                ,ISNULL( (CASE WHEN CIF.GUARANTOR='Y' THEN 'Y' ELSE 'N' END) ,'Y') AS GUR          -- 是否為保證人 (預設 'Y')
                ,ISNULL( (CASE WHEN CIF.FI_CUST='Y' THEN 'Y' ELSE 'N' END) ,'Y') AS FI             -- 是否為同業/金融機構 (預設 'Y')
                ,ISNULL( (CASE WHEN FAC.FAC_COUNT>0 OR DEP.DEP_COUNT>0 THEN 'Y' ELSE 'N' END) ,'N') AS DEP_OR_FAC -- 是否有有效存款或授信往來
                ,CIF.BUSINESS_SECTOR_CODE AS AML_BUZ_SECTOR_CD                                      -- 行業/業務類別代碼
                ,CIF.OPENING_DATE AS AML_OPENING_DATE                                              -- 開戶日期
            FROM dbo.WBS_CIF_CUST_INFO CIF
            
            -- 子查詢 1.1：計算客戶目前有效的存款帳戶數 (CASE_STATUS = '01' 正常)
            LEFT JOIN (
                SELECT COUNT(*) AS DEP_COUNT, DEP.CIF_CUST_INFO_SEQ 
                FROM WBS_DEP_ACC DEP 
                WHERE DEP.CASE_STATUS = '01' 
                GROUP BY DEP.CIF_CUST_INFO_SEQ
            ) DEP ON DEP.CIF_CUST_INFO_SEQ = CIF.CIF_CUST_INFO_SEQ
            
            -- 子查詢 1.2：計算客戶有效授信額度筆數 (過濾特定科目與未結清額度)
            LEFT JOIN (
                SELECT COUNT(*) AS FAC_COUNT, FA.CIF_CUST_INFO_SEQ 
                FROM WBS_FAC_INFO FA 
                LEFT JOIN (
                    SELECT ND.FAC_INFO_SEQ, ND.FAC_NODE_SEQ, ND.OUTSTANDING_BAL
                    FROM WBS_FAC_NODE ND 
                    JOIN WBS_FAC_NODE PD ON ND.PARENT_NODE_SEQ = PD.FAC_NODE_SEQ
                    WHERE ND.NODE_TYPE = '2' AND ND.STATUS = '1'
                    AND (
                        PD.FAC_SUBJECT_CODE NOT IN ('2000','2100','4000','4100') -- 排除特定母層科目
                        OR ND.FAC_SUBJECT_CODE IN (
                            '9403','9404','9405','9406','9407','9408','9409','9410','9411','9412','9415'
                            ,'9416','9417','9419','9420','9421','9422','9423','9424','9425','9426','9427' 
                        )
                    )
                ) NDD ON FA.FAC_INFO_SEQ = NDD.FAC_INFO_SEQ
                -- 授信有效條件：狀態正常('04','05')，或狀態為特定結清狀態但仍有未結清餘額 (OUTSTANDING_BAL <> 0)
                WHERE NDD.FAC_NODE_SEQ IS NOT NULL 
                  AND ( FA.FAC_STATUS IN ('04','05') OR (FA.FAC_STATUS IN ('20','40') AND NDD.OUTSTANDING_BAL <> 0) )
                GROUP BY FA.CIF_CUST_INFO_SEQ
            ) FAC ON FAC.CIF_CUST_INFO_SEQ = CIF.CIF_CUST_INFO_SEQ
        ) CIF
    )

    -- =========================================================================
    -- 2. 主查詢：輸出符合 AML 規範的客戶基本資料欄位規格
    -- =========================================================================
    SELECT
        '' AS No,
        CIF.CustomerID,
        CIF.AML_CUST_TYPE AS CustomerType,        -- 客戶類別：P (個人)、N (法人)
        CIF.AML_CUST_NME AS CustomerName,         -- 優先英文戶名，無英文則帶中文
        CIF.Addr1,
        '' AS Addr2, '' AS Addr3, '' AS Addr4,
        CIF.CtryCD,
        CIF.Nationality,
        '0925' AS Branch_nbr,                     -- 固定納閩分行代號 (0925)
        
        -- AML 統一證號類別：5 代表個人身分證/護照，6 代表法人統編/註冊號
        CASE WHEN CIF.AML_CUST_TYPE = 'P' THEN '5' 
             WHEN CIF.AML_CUST_TYPE = 'N' THEN '6' 
        END AS Unique_Id_Name,
        CIF.CustomerID AS Unique_Id_Value,
        '' AS IDENT_OTH,

        -- 帳戶開立/有效狀態判斷 (Record_Stat: 'O'=Open, 'C'=Close)：
        CASE 
            WHEN CIF.CustomerID = 'MY2199999' THEN 'C'                -- 內部掛帳專用虛擬 CIF 固定設定為關閉/結清
            WHEN CIF_TYPE.CIF_TYPE IN ('A1','A2','B2','C2','D2','E2','F1') THEN CIF.Record_Stat -- 沿用核心原狀態
            WHEN CIF_TYPE.CIF_TYPE IN ('B1_OPEN','C1') THEN 'O'       -- 強制為生效/開立
            WHEN CIF_TYPE.CIF_TYPE IN ('B1_CLOSE','D1','E1') THEN 'C' -- 強制為關閉/結清
            ELSE CIF.Record_Stat
        END AS Record_Stat,

        CIF.AML_CUST_CHI_NME AS Customer_Chi_Name,
        ISNULL(CIF.LOCAL_INDUSTRY_CODE, '999999') AS SIC_Code,       -- 標準行業代碼 (預設補 999999)
        CIF.Phone_No,
        CIF.OFFICE_PHONE,
        CIF.MOBILE,
        CIF.Fax_Number,

        -- 個人戶放出生日期 (Date_Of_Birth)，法人戶放設立登記日 (InCorp_Date)
        CASE WHEN CIF.AML_CUST_TYPE = 'P' THEN CONVERT(VARCHAR(8), CONVERT(DATETIME, CIF.EST_DATE, 111), 112) ELSE '' END AS Date_Of_Birth,
        CASE WHEN CIF.AML_CUST_TYPE = 'N' THEN CONVERT(VARCHAR(8), CONVERT(DATETIME, CIF.EST_DATE, 111), 112) ELSE '' END AS InCorp_Date,
        
        CIF_TYPE.AML_OPENING_DATE AS Creation_date, -- 建立日期 (YYYYMMDD)
        '' AS Checker_DT_Stamp,
        
        -- 行員判斷：業務分類為 '00102' 判定為內部員工 (IsEmployee = 'Y')
        CASE WHEN CIF_TYPE.AML_BUZ_SECTOR_CD = '00102' THEN 'Y' ELSE 'N' END AS IsEmployee,
        'N' AS IsBelievedSuspicious,                -- 是否疑似洗錢預設為 'N'

        -- AML 客群區隔代碼 (Segment_Code)：
        -- ID: 內部帳/特定帳戶, CB: 商業銀行核心客群, NCR: 無往來關係/非核心
        CASE 
            WHEN CIF_TYPE.CIF_TYPE IN ('A1','F1') THEN 'ID'
            WHEN CIF_TYPE.CIF_TYPE IN ('A2','B1_OPEN','B2','C2','D2','E2') THEN 'CB'
            WHEN CIF_TYPE.CIF_TYPE IN ('B1_CLOSE','C1','D1','E1') THEN 'NCR'                
            ELSE 'CB'
        END AS Segment_Code,

        KYC.OCCUPATION AS OccupationCode,           -- 職業代碼 (關聯 KYC 檔)
        CIF_TYPE.AML_BUZ_SECTOR_CD AS OWNERSHIP_CODE,
        '' AS RM_ID,
        CIF.Reg_Address_line1,
        '' AS Reg_Address_line2, '' AS Reg_Address_line3, '' AS Reg_Address_line4,
        '' AS PermanentCountryCode,
        'MYWBS' AS CoreSystem,                      -- 來源核心系統
        CONVERT(VARCHAR(8), DATEADD(D, -1, GETDATE()), 112) AS Processing_Date, -- 批次處理日 (T-1 日)
        '' AS RM_Name, '' AS Alias_Name, '' AS Place_Of_Birth, '' AS Is_Send_Email_Account,
        '' AS Is_Multi_Acc_With_Diff_Name, '' AS Is_Complex_Structure, '' AS Is_Listed_Com_Director

    -- =========================================================================
    -- 3. 資料來源關聯整合 (CIF 清洗子查詢 + CIF_TYPE + KYC)
    -- =========================================================================
    FROM (
        SELECT
            CIF.CIF_CUST_INFO_SEQ,
            CIF.CUSTOMER_ID AS CustomerID,
            CIF.CIF_KYC_SEQ,
            ISNULL(CIF.CUSTOMER_ENG_NAME, CIF.CUSTOMER_NAME) AS AML_CUST_NME,
            CIF.CUSTOMER_NAME AS AML_CUST_CHI_NME,

            -- 電話格式拼接：國碼 + 電話號碼
            ISNULL(CIF.CORRESPONDENCE_TEL_COUNTRY,'') + ISNULL(CIF.CORRESPONDENCE_TEL,'') AS Phone_No,
            ISNULL(CIF.OFFICE_TEL_COUNTRY,'') + ISNULL(CIF.OFFICE_TEL,'') AS OFFICE_PHONE,
            ISNULL(CIF.MOBILE_PHONE_COUNTRY,'') + ISNULL(CIF.MOBILE_PHONE,'') AS MOBILE,
            ISNULL(CIF.FAX_NO_COUNTRY,'') + ISNULL(CIF.FAX_NO,'') AS Fax_Number,

            -- 通訊地址與國籍
            ISNULL(CIF.CORRESPONDENCE_ENG_ADDRESS, CIF.CORRESPONDENCE_ADDRESS) AS Addr1,
            CIF.CORRESPONDENCE_COUNTRY AS CtryCD,
            ISNULL(CIF.REGISTERED_ENG_ADDRESS, CIF.REGISTERED_ADDRESS) AS Reg_Address_line1,
            CIF.COUNTRY AS Nationality,

            -- 身分別判斷：01/03 為個人 (P - Personal)，02/04 為法人 (N - Non-personal)
            CASE WHEN CIF.CUSTOMER_TYPE IN ('01', '03') THEN 'P' 
                 WHEN CIF.CUSTOMER_TYPE IN ('02', '04') THEN 'N' 
            END AS AML_CUST_TYPE,

            CIF.LOCAL_INDUSTRY_CODE,
            CASE WHEN STATUS = '1' THEN 'O' ELSE 'C' END AS Record_Stat, -- 核心系統開合狀態 (1: Open, 其餘: Close)

            -- 日期正規化防呆
            CASE WHEN ISDATE(CIF.ESTABLISH_DATE) = 1 
                 THEN CONVERT(VARCHAR(10), CONVERT(DATETIME, CIF.ESTABLISH_DATE, 112), 20) 
                 ELSE NULL 
            END AS EST_DATE

        FROM dbo.WBS_CIF_CUST_INFO CIF
    ) AS CIF 
    -- 關聯第 1 步計算的客戶屬性分類
    JOIN CIF_TYPE ON CIF.CIF_CUST_INFO_SEQ = CIF_TYPE.CIF_CUST_INFO_SEQ
    -- 關聯 KYC 客戶盡職審查資料表（取職業、高風險註記）
    LEFT JOIN (
        SELECT CIF_KYC_SEQ, OCCUPATION, 
               CASE WHEN RISK_LEVEL = '01' THEN 'Y' ELSE 'N' END AS IS_HIGH_RISK_IND
        FROM dbo.WBS_CIF_KYC
        WHERE STATUS = '1' -- 取生效中的 KYC 資料
    ) AS KYC ON CIF.CIF_KYC_SEQ = KYC.CIF_KYC_SEQ

GO
