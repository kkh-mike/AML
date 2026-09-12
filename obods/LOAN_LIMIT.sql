

/*
核心業務目的為：從核心放款/外匯模組中撈取放款會計科目（13%）的帳戶資料，
將各幣別的貸款金額折算成基準幣別（USD），
並轉換為標準化介面格式（常見於 AML 洗錢防制、風險控管或外部報送系統）。
*/


/*
產品分類處理：
LL / LN（一般貸款 Loan）：關聯 WBS_LON_INFO，取核貸金額 LON_AMT 與交易日 TRADE_DATE。
NG（出口押匯 Negotiation）：關聯 WBS_EXP_NEGO_ITEM，取押匯金額 NEGO_AMT 與異動日 AMEND_DATE。

匯率換算邏輯 (CTE: BOOK_RATE)：
透過 CTE 取得各幣別對 USD 的最新記帳匯率，若換算規則為 M/D 則做倒數運算。
計算出折算後的原始額度，並以「折算後原額度 - 折算後剩餘餘額」推算出已還款金額 (PAYOFF_AMT)。

介面資料介接：
產出許多固定值（如 CORE_SYSTEM = 'MYWBS'、PROCESSING_DATE = 昨日、COLLATERAL_FLAG = 'Y'）
以及保留空字串欄位，這通常是為了配合中台、洗錢防制（AML）、聯徵中心或報送資料倉儲（Data Warehouse）
所定義的固定介面規格（Layout）。
*/

USE [MYDB]
GO

SET ANSI_NULLS ON
GO

SET QUOTED_IDENTIFIER ON
GO

-- 修改貸款額度/帳戶資訊檢視表
ALTER VIEW [dbo].[LOAN_LIMIT] AS

	-- 1. CTE: 計算最新各幣別對美元 (USD) 的記帳匯率 (BOOK_RATE)
	WITH BOOK_RATE AS (
		SELECT
			CCY_CODE AS CCY_CODE,
			CONVERSION,
			-- 根據換算規則決定乘除：Direct/Multiply 則直接取匯率，Multiply/Divide 則取倒數 (1/RATE)
			CASE 
				WHEN CONV.CONVERSION = 'D/M' THEN BOOK_RATE 
				WHEN CONV.CONVERSION = 'M/D' THEN 1 / BOOK_RATE 
				ELSE BOOK_RATE 
			END AS BOOK_RATE
		FROM WBS_CTB_BOOK_RATE RATE
		-- 關聯匯率轉換規則表，鎖定買入幣別為 'USD'
		JOIN WBS_CTB_RATE_CONVERSION CONV 
			ON RATE.CCY_CODE = CONV.SELL_CCY 
			AND CONV.BUY_CCY = 'USD'
		WHERE RATE_TYPE = 'DBU' -- 限外匯業務局/國內外匯業務單位 (DBU) 匯率
		-- 取各幣別最新的匯率更新日
		AND RATE.UPDATE_DATE IN (
			SELECT MAX(UPDATE_DATE) 
			FROM WBS_CTB_BOOK_RATE RATE_DATE 
			WHERE RATE_DATE.RATE_TYPE = 'DBU' 
			GROUP BY RATE_DATE.CCY_CODE
		)
	)

	-- 2. 主查詢：放款帳戶明細與換算
	SELECT 
		-- 帳號：帳號主號 + 分號/序號串接
		LFA.ACCT_NO + SEQ_NO AS ACCOUNT_NBR,
		'LNA' AS APPLICATION_CODE,          -- 應用系統別 (Loan Application)
		LFA.CUST_ID AS CUSTOMER_ID,         -- 客戶統一編號/ID
		-- 分行代碼：左側補 0 至 4 碼
		REPLICATE('0', 4 - LEN(LFA.DUTY_SDN)) + LFA.DUTY_SDN AS BRANCH_NBR,
		'' AS BRANCH_NAME,
		'' AS ACCOUNT_TYPE_CODE,
		'' AS ACCOUNT_TYPE_DESC,
		'' AS OFFICER_NBR,
		'' AS OFFICER_NAME,
		'' AS CURRENT_BALANCE,
		'' AS AVAILABLE_BALANCE,
		LFA.BGN_LN_DT AS OPENING_DATE,      -- 放款起貸日/開戶日
		'' AS CLOSED_DATE,
		-- 帳戶狀態：狀態碼為 '4' 視為有效/結案 (1)，其餘為 0
		CASE LFA.STS_CD WHEN '4' THEN '1' ELSE '0' END AS ACCOUNT_STATUS,
		'' AS OVERDRAFT_LIMIT,

		-- 最後異動日：
		-- 1. 一般放款 ('LL', 'LN') 取放款交易日 (TRADE_DATE)
		-- 2. 出口押匯 ('NG') 取押匯修改日 (AMEND_DATE)
		-- 3. 其餘預設給 '19000101'
		CASE 
			WHEN LFA.PROD_TYP IN ('LL', 'LN') AND LON.TRADE_DATE IS NOT NULL 
				THEN CONVERT(VARCHAR(8), LON.TRADE_DATE, 112)
			WHEN LFA.PROD_TYP = 'NG' AND NEGO.AMEND_DATE IS NOT NULL 
				THEN CONVERT(VARCHAR(8), NEGO.AMEND_DATE, 112)
			ELSE CONVERT(VARCHAR(8), '19000101', 112) 
		END AS DATE_OF_LAST_ACTIVITY,

		-- 放款金額 (LOAN_AMT)：
		-- 原始金額乘上換算後的記帳匯率（若無匯率對應則乘 1），換算為基準幣值 (USD)
		CAST( CAST(
			CASE 
				-- 一般放款 (LL/LN): LON_AMT * 該幣別匯率
				WHEN LFA.PROD_TYP IN ('LL', 'LN') AND LON.LON_AMT IS NOT NULL THEN
					LON.LON_AMT * ISNULL((SELECT BOOK_RATE FROM BOOK_RATE WHERE BOOK_RATE.CCY_CODE = LON.LON_CCY), 1)
				-- 出口押匯 (NG): NEGO_AMT * 該幣別匯率
				WHEN LFA.PROD_TYP = 'NG' AND NEGO.NEGO_AMT IS NOT NULL THEN
					NEGO.NEGO_AMT * ISNULL((SELECT BOOK_RATE FROM BOOK_RATE WHERE BOOK_RATE.CCY_CODE = NEGO.NEGO_CCY), 1)
				ELSE 0 
			END
		AS DECIMAL(24,2) ) AS NVARCHAR ) AS LOAN_AMT,

		-- 已償還/結清金額 (PAYOFF_AMT)：
		-- 計算方式：原始核貸金額(折算) - 目前剩餘餘額 (BAL_AMT 折算)
		CAST( CAST(
			CASE 
				-- 一般放款: 原核貸金額折算 - 帳戶餘額折算
				WHEN LFA.PROD_TYP IN ('LL', 'LN') AND LON.LON_AMT IS NOT NULL AND LFA.BAL_AMT IS NOT NULL THEN
					LON.LON_AMT * ISNULL((SELECT BOOK_RATE FROM BOOK_RATE WHERE BOOK_RATE.CCY_CODE = LON.LON_CCY), 1)
					- LFA.BAL_AMT * ISNULL((SELECT BOOK_RATE FROM BOOK_RATE WHERE BOOK_RATE.CCY_CODE = LFA.CURR_TYP), 1) 
				-- 出口押匯: 原押匯金額折算 - 帳戶餘額折算
				WHEN LFA.PROD_TYP = 'NG' AND NEGO.NEGO_AMT IS NOT NULL AND LFA.BAL_AMT IS NOT NULL THEN
					NEGO.NEGO_AMT * ISNULL((SELECT BOOK_RATE FROM BOOK_RATE WHERE BOOK_RATE.CCY_CODE = NEGO.NEGO_CCY), 1)
					- LFA.BAL_AMT * ISNULL((SELECT BOOK_RATE FROM BOOK_RATE WHERE BOOK_RATE.CCY_CODE = LFA.CURR_TYP), 1)
				ELSE 0 
			END
		AS DECIMAL(24,2) ) AS NVARCHAR ) AS PAYOFF_AMT,

		CONVERT(VARCHAR(10), 0) AS ADVANCE_CAPITAL_REPAYMENT_AMT, -- 提前還本金額 (固定補 0)
		CONVERT(VARCHAR(10), 0) AS LOAN_TERM_MONTH,              -- 貸款期數 (固定補 0)
		'' AS MATURITY_DATE,                                      -- 到期日 (留空)
		'Y' AS COLLATERAL_FLAG,                                   -- 擔保品標記 (固定為 'Y')
		'' AS COLLATERAL_TYPE_CODE,
		'' AS COLLATERAL_TYPE_DESC,
		'' AS OPENING_METHOD_CODE,
		'' AS OPENING_METHOD_DESC,
		'' AS PRODUCT_CODE,
		'' AS PRODUCT_DESC,
		'' AS ACCOUNT_PURPOSE_CODE,
		'' AS ACCOUNT_PURPOSE_DESC,
		CONVERT(VARCHAR(10), 0) AS PAST_DUE_AMT,                  -- 逾期金額 (固定補 0)
		'' AS DELINQUENT_ACC_FLAG,                                -- 催收/呆帳標記 (留空)
		'MYWBS' AS CORE_SYSTEM,                                   -- 資料來源核心系統代碼
		CONVERT(VARCHAR(8), DATEADD(D, -1, GETDATE()), 112) AS PROCESSING_DATE -- 資料處理基準日 (固定為昨天 YYYYMMDD)

	-- 3. 資料來源與關聯
	FROM WBS_LN_FN_ACCT LFA                                       -- 主表：授信/外匯主帳戶檔
	LEFT JOIN WBS_LON_INFO LON                                     -- 放款明細資訊檔 (用 帳號+序號 串接)
		ON ( LFA.ACCT_NO + LFA.SEQ_NO ) = LON.LON_NO
	LEFT JOIN WBS_EXP_NEGO_ITEM NEGO                               -- 出口押匯明細檔 (用 帳號+序號 串接)
		ON ( LFA.ACCT_NO + LFA.SEQ_NO ) = NEGO.REF_NO
	-- 篩選會計科目代碼 (ACC_CD) 為 '13%' 開頭者（通常為銀行資產項下的各項放款、貼現與押匯科目）
	WHERE ACC_CD LIKE '13%' 

GO
