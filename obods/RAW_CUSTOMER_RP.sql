

/*

核心目的，是將核心系統（MYWBS）的客戶股東與關係人明細資料，標準化轉換為下游客戶關係人介面格式（RAW_CUSTOMER_RP），
通常用於洗錢防制（AML）、法遵名單掃描或跨系統整合。
*/


/*

重點維運注意事項

關聯方式為 INNER JOIN：若股東資料庫中的 CIF_CUST_INFO_SEQ 在客戶主檔
 WBS_CIF_CUST_INFO 找不到對應記錄，該筆股東/關係人會直接被過濾掉。

英文與中文姓名分置：Name 欄位只放英文（無資料時補 1 個空格 ' '），中文/原始名稱則存放在最後一欄 Native_Name。

*/

USE [MYDB]
GO

/****** 物件名稱: View [dbo].[RAW_CUSTOMER_RP] 
        業務目的: 將 WBS 系統的股東/董監事資料轉換為標準關係人(RP)介面檔 ******/
SET ANSI_NULLS ON
GO

SET QUOTED_IDENTIFIER ON
GO

ALTER VIEW [dbo].[RAW_CUSTOMER_RP] AS
	SELECT 
		-- 主客戶代號 (取自客戶主檔)
		CIF.CUSTOMER_ID AS CustomerID 
		
		-- 關係人類型代碼 (BOD: 董監事 / MS: 大股東 / APP: 指派人 / OTH: 其他)
		,SH.RP_TYPE AS Related_Parties_Type 
		
		-- 關係人身分識別碼：若無統編/身分證號，則以「客戶代號_股東序號」組合做為唯一虛擬編號
		,ISNULL(SH.HOLDER_ID, CONCAT(CIF.CUSTOMER_ID, '_', SH.CIF_STOCKHOLDER_SEQ)) AS Related_Parties_ID
		
		-- 下游介面保留欄位 (目前未提供，固定給空字串)
		,'' AS Other_Related_Parties_Type 
		,'' AS Other_Related_Parties_Desc
		
		-- 英文姓名：若無英文姓名則補單一空格 ' ' (注意：中文姓名放在最後的 Native_Name)
		,CASE WHEN SH.HOLDER_ENG_NAME IS NULL THEN ' ' ELSE SH.HOLDER_ENG_NAME END AS Name 
		
		-- 下游介面保留欄位 (別名)
		,'' AS Aliases 
		
		-- 關係人主體類型：固定標記為 'I' (Individual / 自然人)
		,'I' AS Type
		
		-- 出生日期 / 設立日期：將來源 YYYYMMDD 字串格式化為 YYYY-MM-DD
		,CASE 
			WHEN SH.ESTABLISH_DATE IS NOT NULL 
			THEN SUBSTRING(SH.ESTABLISH_DATE, 1, 4) + '-' + SUBSTRING(SH.ESTABLISH_DATE, 5, 2) + '-' + RIGHT(SH.ESTABLISH_DATE, 2)
			ELSE SH.ESTABLISH_DATE 
		 END AS DOB
		
		-- 下游介面保留欄位：國籍、戶籍/通訊地址、電話、Email、身分證件明細等 (固定給空字串)
		,'' AS Nationality
		,'' AS P_Addr1 ,'' AS P_Addr2 ,'' AS P_Addr3 ,'' AS P_Country
		,'' AS C_Addr1 ,'' AS C_Addr2 ,'' AS C_Addr3 ,'' AS C_Country
		,'' AS Contact_Phone_No ,'' AS Email
		,'' AS ID_Type ,'' AS ID_Num ,'' AS ID_Issue_Date ,'' AS ID_Expiry_Date ,'' AS ID_Issuing_Country
		,'' AS Remark 
		
		-- 帳戶/資格狀態：'O' (Open / 正常有效), 'C' (Closed / 失效或終止)
		,SH.STATUS AS Status 
		
		-- 資料處理日期 (產檔日)：固定取系統日期的前一天 (YYYY-MM-DD)
		,CONVERT(VARCHAR(10), DATEADD(D, -1, GETDATE()), 20) AS Processing_Date
		
		-- 下游介面保留欄位：開戶/關戶日期
		,'' AS OPENING_DATE 
		,'' AS CLOSED_DATE
		
		-- 來源核心系統代碼
		,'MYWBS' AS CoreSystem
		
		-- 關係人原生姓名 (即中文或本地名稱)
		,SH.HOLDER_NAME AS Native_Name

	FROM (
		-- 內部子查詢 SH：負責清洗與轉換股東明細資料
		SELECT 
			CIF_CUST_INFO_SEQ
			,HOLDER_ID
			-- 將來源系統持股身分類別轉換為標準代碼
			,CASE 
				WHEN HOLD_TYPE = '01' THEN 'BOD'  -- 董監事 (Board of Directors)
				WHEN HOLD_TYPE = '02' THEN 'MS'   -- 大股東 (Major Shareholder)
				WHEN HOLD_TYPE = '03' THEN 'APP'  -- 指派代表人 (Appointed Representative)
				ELSE 'OTH'                        -- 其他 (Others)
			 END AS RP_TYPE
			,CIF_STOCKHOLDER_SEQ
			,HOLDER_NAME
			,HOLDER_ENG_NAME
			,ESTABLISH_DATE
			-- 狀態碼轉換：1 轉為 Open ('O')，其餘轉為 Closed ('C')
			,CASE WHEN STATUS = '1' THEN 'O' ELSE 'C' END AS STATUS
		FROM dbo.WBS_CIF_STOCKHOLDER
	) SH
	-- 關聯客戶主檔：透過內部序號 (CIF_CUST_INFO_SEQ) 帶出對應的主客戶代號 (CUSTOMER_ID)
	JOIN ( 
		SELECT CIF_CUST_INFO_SEQ, CUSTOMER_ID 
		FROM dbo.WBS_CIF_CUST_INFO 
	) CIF ON SH.CIF_CUST_INFO_SEQ = CIF.CIF_CUST_INFO_SEQ
GO
