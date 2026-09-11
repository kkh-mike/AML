USE [MYDB]
GO

/****** Object:  View [dbo].[RAW_CUSTOMER_RP]    Script Date: 2026/9/4 上午 11:25:30 ******/
SET ANSI_NULLS ON
GO

SET QUOTED_IDENTIFIER ON
GO

ALTER View [dbo].[RAW_CUSTOMER_RP] AS
	SELECT 
		CIF.CUSTOMER_ID AS CustomerID ,SH.RP_TYPE AS Related_Parties_Type ,ISNULL(SH.HOLDER_ID,CONCAT(CIF.CUSTOMER_ID,'_',SH.CIF_STOCKHOLDER_SEQ)) AS Related_Parties_ID
		,'' AS Other_Related_Parties_Type ,'' AS Other_Related_Parties_Desc
		,CASE WHEN SH.HOLDER_ENG_NAME IS NULL THEN ' ' ELSE SH.HOLDER_ENG_NAME END Name ,'' AS Aliases ,'I' AS Type
		,CASE WHEN SH.ESTABLISH_DATE IS NOT NULL THEN SUBSTRING(SH.ESTABLISH_DATE,1,4) + '-' + SUBSTRING(SH.ESTABLISH_DATE,5,2) + '-' + RIGHT(SH.ESTABLISH_DATE,2)
			 ELSE SH.ESTABLISH_DATE END AS DOB
		,'' AS Nationality
		,'' AS P_Addr1 ,'' AS P_Addr2 ,'' AS P_Addr3 ,'' AS P_Country
		,'' AS C_Addr1 ,'' AS C_Addr2 ,'' AS C_Addr3 ,'' AS C_Country
		,'' AS Contact_Phone_No ,'' AS Email
		,'' AS ID_Type ,'' AS ID_Num ,'' AS ID_Issue_Date ,'' AS ID_Expiry_Date ,'' AS ID_Issuing_Country
		,'' AS Remark ,SH.STATUS AS Status ,CONVERT(VARCHAR(10), DATEADD(D,-1,GETDATE()), 20) AS Processing_Date
		,'' AS OPENING_DATE ,'' AS CLOSED_DATE
		,'MYWBS' AS CoreSystem
		,SH.HOLDER_NAME AS Native_Name
	FROM (
		SELECT 
			CIF_CUST_INFO_SEQ ,HOLDER_ID
			,CASE WHEN HOLD_TYPE = '01' THEN 'BOD' WHEN HOLD_TYPE = '02' THEN 'MS' WHEN HOLD_TYPE = '03' THEN 'APP' ELSE 'OTH' END AS RP_TYPE
			,CIF_STOCKHOLDER_SEQ ,HOLDER_NAME ,HOLDER_ENG_NAME ,ESTABLISH_DATE
			,CASE WHEN STATUS = '1' THEN 'O' ELSE 'C' END AS STATUS     	  
		FROM dbo.WBS_CIF_STOCKHOLDER
	) SH
	JOIN ( SELECT CIF_CUST_INFO_SEQ,CUSTOMER_ID FROM dbo.WBS_CIF_CUST_INFO ) CIF ON SH.CIF_CUST_INFO_SEQ = CIF.CIF_CUST_INFO_SEQ
	--WHERE SH.HOLDER_ID IS NOT NULL	--正式也有NULL
GO


SELECT Name, * FROM [RAW_CUSTOMER_RP]







/*

這段 View 的邏輯主要是將股東/關係人資料表（WBS_CIF_STOCKHOLDER）
與客戶基本資料表（WBS_CIF_CUST_INFO）進行關聯，
並將欄位格式化轉換為關係人標準介面格式（RAW_CUSTOMER_RP）。

以下為你詳細解析整體的運作邏輯以及 Name 欄位的寫入情境：
一、整體運作邏輯
 * 資料來源與關聯
   * 主表 SH (dbo.WBS_CIF_STOCKHOLDER)：存放股東/關係人的詳細明細。
   * 關聯表 CIF (dbo.WBS_CIF_CUST_INFO)：透過 CIF_CUST_INFO_SEQ 進行 INNER JOIN，主要目的是取得客戶代號 CUSTOMER_ID。
   * 注意：因為是 INNER JOIN，如果 WBS_CIF_STOCKHOLDER 
          中的某些資料找不到對應的 CIF_CUST_INFO_SEQ，該筆記錄將會被排除。


 * 核心欄位轉換規則
   * CustomerID：取自 CIF.CUSTOMER_ID。
   * Related_Parties_Type (RP_TYPE)：依持股/身分類型轉換：
     * '01' \to 'BOD' (董監事 / Board of Directors)
     * '02' \to 'MS' (大股東 / Major Shareholder)
     * '03' \to 'APP' (核定指派人 / Appointed Representative)
     * 其他值 \to 'OTH' (其他 / Others)
   * Related_Parties_ID：優先使用 SH.HOLDER_ID；若為 NULL，則以 CUSTOMER_ID 加上流水號組合成 CustomerID_CIF_STOCKHOLDER_SEQ 作為備用識別碼。
   * DOB (出生/設立日期)：若 SH.ESTABLISH_DATE 有值，會將 YYYYMMDD 格式透過字串擷取拆解為 YYYY-MM-DD 格式。
   * Status：狀態為 '1' 時轉為 'O' (Open)，否則轉為 'C' (Closed)。
   * Processing_Date：取系統當前時間的前一天，格式為 YYYY-MM-DD。
   * 固定/預設值：Type 固定為 'I'（Individual 個人）、CoreSystem 固定為 'MYWBS'，其餘地址、電話、證號等欄位填空字串 ''。

二、什麼情形會寫入 Name 資訊？
在 View 定義中，Name 的產生邏輯為：
CASE WHEN SH.HOLDER_ENG_NAME IS NULL THEN ' ' ELSE SH.HOLDER_ENG_NAME END AS Name

以及最後一行的原生名稱欄位：
SH.HOLDER_NAME AS Native_Name

具體寫入與呈現的情形如下：
 * 情境 1：HOLDER_ENG_NAME 為 NULL
   * Name 欄位會被賦予單一空格字串 ' '（注意不是空字串 ''，而是包含一個空白符號）。
 * 情境 2：HOLDER_ENG_NAME 為空字串 '' 或只含空白
   * 因為不是 NULL，條件不符合 IS NULL，會直接保留原始值（呈現為空字串或空白）。
 * 情境 3：HOLDER_ENG_NAME 有值
   * 直接將原始的英文姓名/外文名稱（例如 'CHEN, DA-MING' 或 'JOHN DOE'）寫入 Name。


   
> 常見維運陷阱提醒：
>  * 此 View 的 Name 只取英文姓名 (HOLDER_ENG_NAME)，中文/本名是寫入在最後面的 Native_Name（對應 SH.HOLDER_NAME）。如果來源系統只維護了中文姓名而未填寫英文姓名，Name 欄位將只會顯示為空白 ' '。
>  * Name 的預設值是 ' '（長度為 1 的空格），而其他多數空欄位使用的是 ''（長度為 0 的空字串），在下游系統做字串長度或空值過濾判斷（如 LEN() = 0 或 TRIM()）時需特別注意。
> 




在這段 View 的結構中，要知道某個 CustomerID 對應到哪些關聯人（Related Parties），主要依賴 兩個欄位的對應關係 以及 關聯建立的鍵值（Key）。
1. View 產出結果如何對應？
在查詢結果中，每一筆紀錄代表**「一個客戶的其中一位關聯人」**：

CustomerID  >>  主客戶  >> 目前是誰的帳戶／公司
Related_Parties_ID >> 關聯人唯一識別碼 >> 關聯人身分證號/統一編號；若為空則為系統自編代碼（CustomerID_SEQ） >>
Name >> 關聯人英文姓名 >> 取自來源的 HOLDER_ENG_NAME >>
Native_Name >> 關聯人中文/本名 >> 取自來源的 HOLDER_NAME >>


Related_Parties_Type >> 關聯身分別 >> BOD（董監事）、MS（大股東）、APP（指派人）、OTH（其他） >>
如何查詢特定客戶的所有關聯人：
SELECT 
    CustomerID,
    Related_Parties_ID,
    Related_Parties_Type,
    Name AS EngName,
    Native_Name AS LocalName,
    Status
FROM [dbo].[RAW_CUSTOMER_RP]
WHERE CustomerID = '想要查詢的客戶代號';

2. 底層資料庫是怎麼串起這層關係的？
從 View 內的 JOIN 條件可以看出串接的底層邏輯：
FROM dbo.WBS_CIF_STOCKHOLDER SH
JOIN dbo.WBS_CIF_CUST_INFO CIF 
  ON SH.CIF_CUST_INFO_SEQ = CIF.CIF_CUST_INFO_SEQ

 * 關聯樞紐：CIF_CUST_INFO_SEQ
   * dbo.WBS_CIF_CUST_INFO 是客戶主檔，定義了客戶代號 CUSTOMER_ID 與它的流水序號 CIF_CUST_INFO_SEQ。
   * dbo.WBS_CIF_STOCKHOLDER 是關聯人/股東明細檔，裡面的外鍵（FK）欄位就是 CIF_CUST_INFO_SEQ。
 * 一對多（1 : N）結構：
   * 一個 CUSTOMER_ID（一筆 CIF_CUST_INFO_SEQ）在 WBS_CIF_STOCKHOLDER 中可以對應多筆紀錄。
   * 因此，當你對該 View 進行查詢時，同一個 CustomerID 會出現多行，每一行就代表該客戶旗下的一名董事、監察人或大股東。



用最白話的「存摺與聯絡人」概念來說明：
 * WBS_CIF_CUST_INFO（客戶主檔）
   * 就像公司的基本檔案夾。
   * 系統給每家公司發一張號碼牌 CIF_CUST_INFO_SEQ（例如編號 1001 對應客戶代號 A公司）。
 * WBS_CIF_STOCKHOLDER（關係人名冊）
   * 就像一張張董監事名片。
   * 每張名片背面都蓋上所屬公司的編號 1001（CIF_CUST_INFO_SEQ）。
 * JOIN 串接在做的事
   * 系統拿著編號 1001，把背面蓋有 1001 的名片通通挑出來，並在每張名片上補印「這是 A公司 的人」。
   * 一家公司通常有多位董監事（一對多），所以查詢結果中，同一個 A公司 會分行列出張三（董事）、李四（監察人）等人。



   
3. 如果想統計每位客戶底下的關聯人數量
可以透過簡單的 GROUP BY 查看哪些客戶擁有關聯人以及人數：
SELECT 
    CustomerID,
    COUNT(1) AS Total_RP_Count,
    -- 統計活躍狀態的關聯人數量
    SUM(CASE WHEN Status = 'O' THEN 1 ELSE 0 END) AS Active_RP_Count
FROM [dbo].[RAW_CUSTOMER_RP]
GROUP BY CustomerID
ORDER BY Total_RP_Count DESC;

*/
