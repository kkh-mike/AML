USE [MYDB]
GO

/****** Object:  View [dbo].[RAW_WIRE_TRXN]    Script Date: 2026/9/11 下午 05:40:46 ******/
SET ANSI_NULLS ON
GO

SET QUOTED_IDENTIFIER ON
GO


/*  
 * 2020/09/18 納閩分行洗錢防制系統建置 AML  每日批次來源檔(WBS_DEP_FN_MBBIRMAS、WBS_DEP_FN_MBBORMAS)   
 * 2022/01/14 AML本位幣由MYR改為USD 
 * 2022/10/20 排除STSDESC = 'AMENDMENT'
*/
ALTER View [dbo].[RAW_WIRE_TRXN] AS 

	WITH BOOK_RATE AS (
		SELECT CCY_CODE AS CCY_CODE ,CONVERSION ,CASE WHEN CONV.CONVERSION='D/M' THEN BOOK_RATE WHEN CONV.CONVERSION='M/D' THEN 1/BOOK_RATE ELSE BOOK_RATE END AS BOOK_RATE
		FROM WBS_CTB_BOOK_RATE RATE JOIN WBS_CTB_RATE_CONVERSION CONV ON RATE.CCY_CODE=CONV.SELL_CCY AND CONV.BUY_CCY='USD'
		WHERE RATE_TYPE='DBU' --AND WBS_CTB_RATE.UPDATE_DATE=CONVERT(VARCHAR(10),GETDATE()-1,112)
		AND RATE.UPDATE_DATE IN ( SELECT MAX(UPDATE_DATE) FROM WBS_CTB_BOOK_RATE RATE_DATE WHERE RATE_DATE.RATE_TYPE='DBU' GROUP BY RATE_DATE.CCY_CODE )
	)
   SELECT 
	   IRS.REFNO AS TRANSACTION_ID ,IRS.CUSTCOD AS CUSTOMER_ID ,IRS.REFNO AS ACCOUNT_NBR ,'SAV' AS APPLICATION_CODE
	   ,CAST( IRS.REMITAM*ISNULL((SELECT BOOK_RATE FROM BOOK_RATE WHERE BOOK_RATE.CCY_CODE=IRS.REMITCY),1) AS VARCHAR) AS AMOUNT_IN ,'0' AS AMOUNT_OUT
	   ,'' AS TRANSACTION_CODE ,'' AS TRANSACTION_DESC
	   ,'' AS TELLER_ID ,'3' AS TELLER_TYPE ,'Branch Teller' AS TELLER_TYPE_DESC
	   ,IRS.ADATE AS TRANSACTION_DATE
	   ,'' AS CURRENCY_CODE ,'' AS ORI_AMOUNT_IN ,'' AS ORI_AMOUNT_OUT
	   ,IRS.BCH0001 AS BRANCH_OF_TRXN /*ORDBANK AS BANK_NBR,*/ ,'MY' AS BANK_NBR

	   ,'' AS IMAD ,'' AS OMAD 
	   ,'' AS Sender_Bank_ABA ,REPLACE(REPLACE(REPLACE(IRS.ORDBAD1,CHAR(9),''),CHAR(10),''),CHAR(13),'') AS Sender_Bank_Name ,SUBSTRING(IRS.ORDBANK,5,2) AS Sender_Bank_Country_Code
	   ,'' AS Receiver_Bank_ABA ,'' AS Receiver_Bank_Name ,'' AS Receiver_Bank_Country_Code

	   ,'' AS Originator_ID_Code ,IIF( LEFT(IRS.ORDCUS1,1) = '/' ,IRS.ORDCUS1 ,'') AS Originator_ID ,IIF( LEFT(IRS.ORDCUS1,1) = '/' ,IRS.ORDCUS2 ,'') AS Originator_Name
	   ,'' AS Originator_Address_1 ,'' AS Originator_Address_2 ,'' AS Originator_Address_3 ,'' AS Originator_Customer_Country_Code  /*以CUSTCOD 至CIF取得國別*/

	   ,'' AS Originator_Bank_ID_Code ,'' AS Originator_Bank_ID ,'' AS Originator_Bank_Name 
	   ,'' AS Originator_Bank_Address_1 ,'' AS Originator_Bank_Address_2 ,'' AS Originator_Bank_Address_3 ,SUBSTRING(IRS.ORDBANK,5,2) AS Originator_Bank_Country_Code

	   ,'' AS Intermediary_Bank_ID_Code ,'' AS Intermediary_Bank_ID ,'' AS Intermediary_Bank_Name
	   ,'' AS Intermediary_Bank_Address_1 ,'' AS Intermediary_Bank_Address_2 ,'' AS Intermediary_Bank_Address_3 ,SUBSTRING(IRS.INTBANK,5,2) AS Intermediary_Bank_Country_Code

	   ,'' AS Beneficiary_Bank_ID_Code ,'' AS Beneficiary_Bank_ID ,'' AS Beneficiary_Bank_Name
	   ,'' AS Beneficiary_Bank_Address_1 ,'' AS Beneficiary_Bank_Address_2 ,'' AS Beneficiary_Bank_Address_3 ,SUBSTRING(IRS.ACWBANK,5,2) AS Beneficiary_Bank_Country_Code

	   ,'' AS Beneficiary_ID_Code ,IRS.BENAC AS Beneficiary_ID ,REPLACE(REPLACE(REPLACE(CONCAT(LTRIM(IRS.BENADD1),LTRIM(BENADD2)),CHAR(9),''),CHAR(10),''),CHAR(13),'') AS Beneficiary_Name
	   ,'' AS Beneficiary_Address_1 ,'' AS Beneficiary_Address_2 ,'' AS Beneficiary_Address_3 ,'' AS Beneficiary_Customer_Country_Code   /*以BENCODE 至CIF取得國別*/

	   ,'' AS Senders_correspondent_ID ,'' AS Senders_correspondent_Name
	   ,'' AS Senders_correspondent_Address_1 ,'' AS Senders_correspondent_Address_2 ,'' AS Senders_correspondent_Address_3 
	   ,'' AS Senders_correspondent_Country_Code 

	   ,'' AS Receivers_correspondent_ID ,'' AS Receivers_correspondent_Name
	   ,'' AS Receivers_correspondent_Address_1 ,'' AS Receivers_correspondent_Address_2 ,'' AS Receivers_correspondent_Address_3 
	   ,SUBSTRING(IRS.RECOBAN,5,2) AS Receivers_correspondent_Country_Code

	   ,'' AS Payment_Method
	   ,'' AS Foreign_or_Domestic_Wire
	   ,'MYWBS' AS CORE_SYSTEM ,CONVERT(VARCHAR(10), DATEADD(D,-1,GETDATE()) ,20) AS PROCESSING_DATE
	   ,'I' AS Direction
	   ,'' AS CONDUCTOR_ID
	   ,'N' AS Correspondent_Bank_Tran_Flag
	   
	   /*,'' AS Foreign_Currency_Exchange_Flag
	   ,'' AS SAR_Exclude_Flag
	   ,'' AS Cash_Flag*/   
   
   FROM WBS_DEP_FN_MBBIRMAS IRS
   /*LEFT JOIN CIF表*/
   WHERE IRS.RECTYPE = 'M'
   AND ( IRS.ADATE = CONVERT(VARCHAR(10),DATEADD(D,-1,GETDATE()),112) OR @@SERVERNAME LIKE '%TEST%' )
   AND STSDESC <> 'AMENDMENT'
 
   UNION ALL 
   
   SELECT
	   ORS.REFNO  AS TRANSACTION_ID ,ORS.CUSTCOD AS CUSTOMER_ID ,ORS.REFNO AS ACCOUNT_NBR ,'SAV' AS APPLICATION_CODE
	   ,'0' AS AMOUNT_IN ,CAST( REMITAM*ISNULL((SELECT BOOK_RATE FROM BOOK_RATE WHERE BOOK_RATE.CCY_CODE=ORS.REMITCY),1) AS VARCHAR ) AS AMOUNT_OUT
	   ,'' AS TRANSACTION_CODE ,'' AS TRANSACTION_DESC
	   ,'' AS TELLER_ID ,'3' AS TELLER_TYPE
	   ,'Branch Teller' AS TELLER_TYPE_DESC
	   ,ORS.ADATE AS TRANSACTION_DATE
	   ,'' AS CURRENCY_CODE ,'' AS ORI_AMOUNT_IN ,'' AS ORI_AMOUNT_OUT
	   ,ORS.BCH0001 AS BRANCH_OF_TRXN ,'MY' AS BANK_NBR

	   ,'' AS IMAD ,'' AS OMAD
	   ,'' AS Sender_Bank_ABA ,'' AS Sender_Bank_Name ,'' AS Sender_Bank_Country_Code
	   ,'' AS Receiver_Bank_ABA ,REPLACE(REPLACE(REPLACE(ORS.AWB1AD1,CHAR(9),''),CHAR(10),''),CHAR(13),'') AS Receiver_Bank_Name
	   ,REPLACE(REPLACE(REPLACE(SUBSTRING(ORS.AWB100,5,2),CHAR(9),''),CHAR(10),''),CHAR(13),'') AS Receiver_Bank_Country_Code

	   ,'' AS Originator_ID_Code ,IIF( LEFT(ORDCUS1,1) = '/' ,ORDCUS1 ,'') AS ORIGINATOR_ID ,IIF( LEFT(ORDCUS1,1) = '/' ,ORDCUS2 ,'') AS ORIGINATOR_NAME
	   ,'' AS Originator_Address_1 ,'' AS Originator_Address_2 ,'' AS Originator_Address_3 ,'' AS Originator_Customer_Country_Code /*以CUSTCOD 至CIF取得國別*/

	   ,'' AS Originator_Bank_ID_Code ,'' AS Originator_Bank_ID ,'' AS Originator_Bank_Name 
	   ,'' AS Originator_Bank_Address_1 ,'' AS Originator_Bank_Address_2 ,'' AS Originator_Bank_Address_3 ,SUBSTRING(ORS.ORBKCOD,5,2) AS Originator_Bank_Country_Code
	   
	   ,'' AS Intermediary_Bank_ID_Code ,'' AS Intermediary_Bank_ID ,'' AS Intermediary_Bank_Name
	   ,'' AS Intermediary_Bank_Address_1 ,'' AS Intermediary_Bank_Address_2 ,'' AS Intermediary_Bank_Address_3 ,SUBSTRING(ORS.INTBANK,5,2) AS Intermediary_Bank_Country_Code

	   ,'' AS Beneficiary_Bank_ID_Code ,'' AS Beneficiary_Bank_ID ,'' AS Beneficiary_Bank_Name
	   ,'' AS Beneficiary_Bank_Address_1 ,'' AS Beneficiary_Bank_Address_2 ,'' AS Beneficiary_Bank_Address_3 ,SUBSTRING(ORS.AWB100,5,2) AS Beneficiary_Bank_Country_Code

	   ,'' AS Beneficiary_ID_Code ,ORS.BENAC AS Beneficiary_ID ,LTRIM(ORS.BENADD1)+LTRIM(ORS.BENADD2) AS Beneficiary_Name 
	   ,'' AS Beneficiary_Address_1 ,'' AS Beneficiary_Address_2 ,'' AS Beneficiary_Address_3 ,'' AS Beneficiary_Customer_Country_Code /*以IDNO 至CIF取得國別*/

	   ,'' AS Senders_correspondent_ID ,'' AS Senders_correspondent_Name
	   ,'' AS Senders_correspondent_Address_1 ,'' AS Senders_correspondent_Address_2 ,'' AS Senders_correspondent_Address_3 
	   ,SUBSTRING(ORS.SECOBAN,5,2) AS Senders_correspondent_Country_Code

	   ,'' AS Receivers_correspondent_ID ,'' AS Receivers_correspondent_Name
	   ,'' AS Receivers_correspondent_Address_1 ,'' AS Receivers_correspondent_Address_2 ,'' AS Receivers_correspondent_Address_3
	   ,'' AS Receivers_correspondent_Country_Code

	   ,'' AS Payment_Method
	   ,'' AS Foreign_or_Domestic_Wire
	   ,'MYWBS' AS CORE_SYSTEM ,CONVERT(VARCHAR(10), DATEADD(D,-1,GETDATE()), 20) AS PROCESSING_DATE
	   ,'O' AS DIRECTION
	   ,'' AS CONDUCTOR_ID
	   ,'N' AS Correspondent_Bank_Tran_Flag
	   
	   /*,'' AS Foreign_Currency_Exchange_Flag
	   ,'' AS SAR_Exclude_Flag
	   ,'' AS Cash_Flag*/
    
   FROM WBS_DEP_FN_MBBORMAS ORS
   /*LEFT JOIN CIF表*/
   WHERE ORS.RECTYPE = 'M' 
   AND ( ORS.ADATE = CONVERT(VARCHAR(10),DATEADD(D,-1,GETDATE()),112) OR @@SERVERNAME LIKE '%TEST%' )
   AND STSDESC <> 'AMENDMENT'


GO

