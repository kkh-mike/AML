/*
========================================================================================
腳本名稱：OFAC_DJ_Sanctions_IDs批次同步與驗證腳本.sql
主要定位：第 3 段 Sanctions IDs 資料同步與維護 (固定 GROUPID = 10)
目標主表：BSADB.dbo.OFAC_GLSpec
稽核日誌：BSADB.dbo.OFAC_GLSpec_Log

[適用對象]
系統維運人員、DBA

[使用時機]
1. 第 3 段 Sanctions IDs 排程失敗，需手動補跑時。
2. 需預覽本次 Sanctions IDs 變更筆數 (Dry-Run) 時。

[核心邏輯說明]
- 將受制裁實體的證件號碼 (IdentificationNumber) 寫入 spec_name 欄位。
- 比對三欄複合鍵：spec_name (證件號) + remark (實體編號) + IdentificationType (證件類型)。
- ADDRESS 欄位填入證件類型與 Dow Jones 網站提示字串。
========================================================================================
*/

-- =====================================================================================
-- [STEP 1] 來源資料清洗與暫存
-- =====================================================================================
IF OBJECT_ID('tempdb..#tempDJBlacklistSID') IS NOT NULL
    DROP TABLE #tempDJBlacklistSID;

IF OBJECT_ID('tempdb..#tempDJBlacklistDetailsSID') IS NOT NULL
    DROP TABLE #tempDJBlacklistDetailsSID;

CREATE TABLE #tempDJBlacklistSID
(
    EntNum               INT NOT NULL,
    IdentificationType   NVARCHAR(100) NOT NULL,
    IdentificationNumber NVARCHAR(350) NOT NULL,
    UpdatedDate          VARCHAR(8) NOT NULL
);

CREATE TABLE #tempDJBlacklistDetailsSID
(
    EntNum               INT NOT NULL,
    IdentificationNumber NVARCHAR(350) NOT NULL,
    IdentificationType   NVARCHAR(350) NOT NULL,
    UpdatedDate          VARCHAR(8) NOT NULL,
    Address              NVARCHAR(400),
    City                 NVARCHAR(200),
    Country              NVARCHAR(100),
    IdentType            VARCHAR(2),
    IdentNumber          NVARCHAR(44),
    DOB                  VARCHAR(8)
);

-- 取得符合條件的 Sanctions ID
INSERT INTO #tempDJBlacklistSID (EntNum, IdentificationType, IdentificationNumber, UpdatedDate)
SELECT 
    A.EntityId,
    D.IdentificationType,
    D.IdentificationNumber,
    MAX(C.UpdatedDate) AS UpdatedDate
FROM BSADB.dbo.DJ_Entity A WITH (NOLOCK)
JOIN BSADB.dbo.DJ_ListCategory B WITH (NOLOCK) ON A.EntityId = B.EntityId
JOIN BSADB.dbo.DJ_List_Data_A C WITH (NOLOCK)  ON A.EntityId = C.EntNum
LEFT JOIN BSADB.dbo.DJ_IdentificationTypeInfo D WITH (NOLOCK) ON A.EntityId = D.EntityId
WHERE A.PersonStatus <> 'Inactive'
  AND (
        B.Description2 = 'Sanctions Lists'
     OR B.Description3 IN (
            'OFAC Related - Majority Owned',
            'OFAC Related - Control',
            'OFAC - Regional Sanctions Related - Majority Owned',
            'OFAC - Regional Sanctions Related - Control',
            'EU Related - Majority Owned',
            'EU Related - Control',
            'EU - Regional Sanctions Related - Majority Owned',
            'EU - Regional Sanctions Related - Control'
        )
      )
  AND B.Deleted = 0
  AND D.IdentificationType IN (
        'Aircraft Construction, Line, Fleet or Serial Number',
        'Aircraft Manufacturer''s Serial Number (MSN)',
        'Bank Identifier Code (BIC)',
        'Central Registration Depository (CRD)',
        'Company Identification No.',
        'Driving Licence No.',
        'DUNS Number',
        'International Maritime Organization (IMO) Ship No.',
        'International Securities Identification Number (ISIN)',
        'Legal Entity Identifier (LEI)',
        'National ID',
        'National Provider Identifier (NPI)',
        'National Tax No.',
        'Others',
        'Passport No.',
        'Social Security No.',
        'Email',
        'Fax',
        'Phone'
      )
  AND D.Deleted = 0
GROUP BY 
    A.EntityId, 
    D.IdentificationType, 
    D.IdentificationNumber;

-- 準備明細資料（將 IdentificationType 存入 ADDRESS 欄位供後續比對）
INSERT INTO #tempDJBlacklistDetailsSID
    (EntNum, IdentificationNumber, IdentificationType, UpdatedDate, Address)
SELECT 
    A.EntNum,
    A.IdentificationNumber,
    A.IdentificationType,
    A.UpdatedDate,
    A.IdentificationType + '; Please go to Dowjones website for more detail'
FROM #tempDJBlacklistSID A;

CREATE CLUSTERED INDEX IX_TempDetailsSID_Key 
    ON #tempDJBlacklistDetailsSID(IdentificationNumber, EntNum, IdentificationType);


-- =====================================================================================
-- [STEP 2] 同步前預覽分析 (Dry-Run)
-- =====================================================================================
;WITH TargetTable AS
(
    SELECT 
        A.*,
        REPLACE(A.ADDRESS, '; Please go to Dowjones website for more detail', '') AS ExtractedIdentType
    FROM BSADB.dbo.OFAC_GLSpec A WITH (NOLOCK)
    WHERE A.GROUPID = 10
)
SELECT 
    CASE 
        WHEN T.spec_name IS NULL THEN '1. 即將新增 (Insert)'
        WHEN T.DInd = 'Y'        THEN '2. 即將重新啟用 (Reactivate)'
        WHEN S.UpdatedDate <> T.updated_date THEN '3. 即將更新資料 (Update)'
    END AS ActionPlan,
    S.EntNum,
    S.IdentificationType,
    S.IdentificationNumber,
    T.DInd AS Current_DInd,
    T.updated_date AS Internal_UpdatedDate,
    S.UpdatedDate  AS DJ_UpdatedDate
FROM #tempDJBlacklistDetailsSID S
LEFT JOIN TargetTable T
    ON T.spec_name = S.IdentificationNumber
   AND T.remark = CAST(S.EntNum AS VARCHAR(100))
   AND T.ExtractedIdentType = S.IdentificationType
WHERE T.spec_name IS NULL 
   OR T.DInd = 'Y'
   OR (T.DInd = 'N' AND S.UpdatedDate <> T.updated_date)

UNION ALL

SELECT 
    '4. 即將軟刪除 (Soft Delete)' AS ActionPlan,
    CAST(T.remark AS INT) AS EntNum,
    T.ExtractedIdentType AS IdentificationType,
    T.spec_name AS IdentificationNumber,
    T.DInd AS Current_DInd,
    T.updated_date AS Internal_UpdatedDate,
    NULL AS DJ_UpdatedDate
FROM TargetTable T
LEFT JOIN #tempDJBlacklistDetailsSID S
    ON T.spec_name = S.IdentificationNumber
   AND T.remark = CAST(S.EntNum AS VARCHAR(100))
   AND T.ExtractedIdentType = S.IdentificationType
WHERE T.DInd = 'N'
  AND S.EntNum IS NULL;


-- =====================================================================================
-- [STEP 3] 核心 MERGE 同步作業
-- =====================================================================================
BEGIN TRANSACTION;

BEGIN TRY
    ;WITH TargetTable AS
    (
        SELECT 
            A.*,
            REPLACE(A.ADDRESS, '; Please go to Dowjones website for more detail', '') AS IdentificationType
        FROM BSADB.dbo.OFAC_GLSpec A
        WHERE A.GROUPID = 10
    )
    MERGE TargetTable AS T
    USING
    (
        SELECT 
            EntNum, IdentificationNumber, IdentificationType, UpdatedDate, Address,
            City, Country, IdentType, IdentNumber, DOB
        FROM #tempDJBlacklistDetailsSID
    ) AS S
    ON T.spec_name = S.IdentificationNumber
   AND T.remark = CAST(S.EntNum AS VARCHAR(100))
   AND T.IdentificationType = S.IdentificationType

    WHEN NOT MATCHED BY TARGET THEN
        INSERT (spec_name, updated_date, remark, TaxID, IDENT, IDENTO, TaxIDCD, IDNUM, IssBy, DInd,
                creUserID, STATE, ADDRESS, COUNTRY, GROUPID, SOURCE, EnterFlag,
                ApprovedBy, ApprovedDate, DelUserID, DelDate, ApproveDelUserID, ApproveDelDate,
                creDate, updated_date_UTC, ApprovedDate_UTC, DelDate_UTC, ApproveDelDate_UTC, creDate_UTC, DOB)
        VALUES (S.IdentificationNumber, S.UpdatedDate, S.EntNum, '', S.IdentType, S.IdentNumber, '', '', '',
                'N', 'System Admin', ISNULL(S.City, ''), S.Address, S.Country, '10', 'Sanctions IDs', 'D',
                'System Admin', GETDATE(), NULL, NULL, NULL, NULL,
                GETDATE(), GETUTCDATE(), GETUTCDATE(), NULL, NULL, GETUTCDATE(), S.DOB)

    WHEN NOT MATCHED BY SOURCE AND T.DInd = 'N' THEN
        UPDATE SET 
            T.DInd = 'Y',
            T.DelUserID = 'System Admin',
            T.DelDate = GETDATE(),
            T.ApproveDelUserID = 'System Admin',
            T.ApproveDelDate = GETDATE(),
            T.DelDate_UTC = GETUTCDATE()

    WHEN MATCHED AND (T.DInd = 'Y' OR S.UpdatedDate <> T.updated_date) THEN
        UPDATE SET 
            T.DInd = 'N',
            T.updated_date = S.UpdatedDate,
            T.DelUserID = NULL,
            T.DelDate = NULL,
            T.ApproveDelUserID = NULL,
            T.ApproveDelDate = NULL,
            T.DelDate_UTC = NULL,
            T.EnterFlag = 'D',
            T.updated_date_UTC = GETUTCDATE(),
            T.ADDRESS = S.Address,
            T.STATE = ISNULL(S.City, ''),
            T.COUNTRY = S.Country,
            T.IDENT = S.IdentType,
            T.IDNUM = S.IdentNumber,
            T.DOB = S.DOB

    OUTPUT 
        CASE WHEN $ACTION IN ('INSERT') THEN Inserted.ent_num ELSE Deleted.ent_num END,
        CASE WHEN $ACTION IN ('INSERT') THEN Inserted.spec_name ELSE Deleted.spec_name END,
        CASE WHEN $ACTION IN ('INSERT') THEN Inserted.updated_date ELSE Deleted.updated_date END,
        CASE WHEN $ACTION IN ('INSERT') THEN Inserted.remark ELSE Deleted.remark END,
        CASE WHEN $ACTION IN ('INSERT') THEN Inserted.DInd ELSE Deleted.DInd END,
        CASE WHEN $ACTION IN ('INSERT') THEN Inserted.creUserID ELSE Deleted.creUserID END,
        CASE WHEN $ACTION IN ('INSERT') THEN Inserted.IDENTO ELSE Deleted.IDENTO END,
        CASE WHEN $ACTION IN ('INSERT') THEN Inserted.STATE ELSE Deleted.STATE END,
        CASE WHEN $ACTION IN ('INSERT') THEN Inserted.ADDRESS ELSE Deleted.ADDRESS END,
        CASE WHEN $ACTION IN ('INSERT') THEN Inserted.COUNTRY ELSE Deleted.COUNTRY END,
        CASE WHEN $ACTION IN ('INSERT') THEN Inserted.GROUPID ELSE Deleted.GROUPID END,
        CASE WHEN $ACTION IN ('INSERT') THEN Inserted.IDENT ELSE Deleted.IDENT END,
        CASE WHEN $ACTION IN ('INSERT') THEN Inserted.IDNUM ELSE Deleted.IDNUM END,
        CASE WHEN $ACTION IN ('INSERT') THEN Inserted.DOB ELSE Deleted.DOB END,
        CASE WHEN $ACTION IN ('INSERT') THEN Inserted.EnterFlag ELSE Deleted.EnterFlag END,
        CASE WHEN $ACTION IN ('INSERT') THEN Inserted.ApprovedBy ELSE Deleted.ApprovedBy END,
        CASE WHEN $ACTION IN ('INSERT') THEN Inserted.ApprovedDate ELSE Deleted.ApprovedDate END,
        CASE WHEN $ACTION IN ('INSERT') THEN Inserted.DelUserID ELSE Deleted.DelUserID END,
        CASE WHEN $ACTION IN ('INSERT') THEN Inserted.DelDate ELSE Deleted.DelDate END,
        CASE WHEN $ACTION IN ('INSERT') THEN Inserted.ApproveDelUserID ELSE Deleted.ApproveDelUserID END,
        CASE WHEN $ACTION IN ('INSERT') THEN Inserted.ApproveDelDate ELSE Deleted.ApproveDelDate END,
        CASE WHEN $ACTION IN ('INSERT') THEN Inserted.creDate ELSE Deleted.creDate END,
        CASE WHEN $ACTION IN ('INSERT') THEN Inserted.updated_date_UTC ELSE Deleted.updated_date_UTC END,
        CASE WHEN $ACTION IN ('INSERT') THEN Inserted.ApprovedDate_UTC ELSE Deleted.ApprovedDate_UTC END,
        CASE WHEN $ACTION IN ('INSERT') THEN Inserted.DelDate_UTC ELSE Deleted.DelDate_UTC END,
        CASE WHEN $ACTION IN ('INSERT') THEN Inserted.ApproveDelDate_UTC ELSE Deleted.ApproveDelDate_UTC END,
        CASE WHEN $ACTION IN ('INSERT') THEN Inserted.creDate_UTC ELSE Deleted.creDate_UTC END,
        CASE 
            WHEN $ACTION = 'INSERT' OR ($ACTION = 'UPDATE' AND Deleted.DInd = 'Y' AND Inserted.DInd = 'N') THEN '01'
            WHEN $ACTION = 'UPDATE' AND Inserted.DInd = 'Y' THEN '03'
            ELSE '02'
        END,
        GETUTCDATE()
    INTO BSADB.dbo.OFAC_GLSpec_Log
        (ent_num, spec_name, updated_date, remark, DInd, creUserID, IDENTO, STATE, ADDRESS, COUNTRY, GROUPID,
         IDENT, IDNUM, DOB, EnterFlag, ApprovedBy, ApprovedDate, DelUserID, DelDate, ApproveDelUserID,
         ApproveDelDate, CreationDate, updated_date_UTC, ApprovedDate_UTC, DelDate_UTC, ApproveDelDate_UTC,
         CreationDate_UTC, ActionCD, ActionDt);

    COMMIT TRANSACTION;
    PRINT 'Sanctions IDs 同步作業執行成功。';
END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0
        ROLLBACK TRANSACTION;

    PRINT 'Sanctions IDs 同步作業發生錯誤，已復原交易。';
    THROW;
END CATCH;


-- =====================================================================================
-- [STEP 4] 清理暫存表
-- =====================================================================================
IF OBJECT_ID('tempdb..#tempDJBlacklistSID') IS NOT NULL 
    DROP TABLE #tempDJBlacklistSID;

IF OBJECT_ID('tempdb..#tempDJBlacklistDetailsSID') IS NOT NULL 
    DROP TABLE #tempDJBlacklistDetailsSID;
