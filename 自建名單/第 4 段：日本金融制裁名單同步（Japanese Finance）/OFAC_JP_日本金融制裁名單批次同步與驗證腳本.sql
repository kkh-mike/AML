/*
========================================================================================
腳本名稱：OFAC_JP_日本金融制裁名單批次同步與驗證腳本.sql
主要定位：第 4 段 日本金融制裁名單資料同步與維護 (跨庫 BSADBJP..OFAC_SPEC，GROUPID = 5)
目標主表：BSADBJP..OFAC_SPEC
稽核日誌：BSADBJP.dbo.OFAC_SPEC_LOG

[適用對象]
系統維運人員、DBA

[使用時機]
1. 第 4 段 日本金融制裁名單排程失敗，需手動補跑時。
2. 需預覽本次日本名單變更筆數 (Dry-Run) 時。

[核心邏輯說明]
- 篩選 SanctionListReference 包含 'Japanese Finance' 之主要名單及死亡名單。
- 自動計算並指派主表流水號 (ent_num)。
- 同步至 BSADBJP..OFAC_SPEC 並記錄稽核歷程至 BSADBJP.dbo.OFAC_SPEC_LOG。
========================================================================================
*/

-- =====================================================================================
-- [STEP 0] 前置代碼定義
-- =====================================================================================
DECLARE @OtherIdentMthCode VARCHAR(2);
SELECT @OtherIdentMthCode = IDENTCODE 
FROM dbo.IDENTMTHD_DIM 
WHERE OTHIND = 'Y';


-- =====================================================================================
-- [STEP 1] 來源資料清洗與暫存
-- =====================================================================================
IF OBJECT_ID('tempdb..#tempDJBlacklistJP') IS NOT NULL
    DROP TABLE #tempDJBlacklistJP;

IF OBJECT_ID('tempdb..#tempDJBlacklistDetailsJP') IS NOT NULL
    DROP TABLE #tempDJBlacklistDetailsJP;

CREATE TABLE #tempDJBlacklistJP
(
    EntNum      INT NOT NULL,
    SdnName     NVARCHAR(350) NOT NULL,
    UpdatedDate VARCHAR(8) NOT NULL
);

CREATE TABLE #tempDJBlacklistDetailsJP
(
    Num         INT,
    EntNum      INT NOT NULL,
    SdnName     NVARCHAR(350) NOT NULL,
    UpdatedDate VARCHAR(8) NOT NULL,
    Address     NVARCHAR(400),
    City        NVARCHAR(200),
    Country     NVARCHAR(100),
    IdentType   VARCHAR(2),
    IdentNumber NVARCHAR(44),
    DOB         VARCHAR(8)
);

-- 1.1 取得符合條件的 Japanese Finance 主要名單
INSERT INTO #tempDJBlacklistJP (EntNum, SdnName, UpdatedDate)
SELECT 
    A.EntNum, 
    A.SdnName, 
    MAX(A.UpdatedDate) AS UpdatedDate
FROM BSADB.dbo.DJ_List_Data_A A WITH (NOLOCK)
JOIN BSADB.dbo.DJ_SanctionListReference B WITH (NOLOCK) ON A.EntNum = B.EntityId
WHERE A.NamePropertyBitCode & 1 > 0
  AND B.SanctionListReference LIKE '%Japanese Finance%'
GROUP BY A.EntNum, A.SdnName;

-- 1.2 擴大納入死亡名單掃描 (Deceased = 1)
INSERT INTO #tempDJBlacklistJP (EntNum, SdnName, UpdatedDate)
SELECT 
    A.EntityId, 
    A.FullName, 
    MAX(CONVERT(VARCHAR, A.UpdatedDate_UTC, 112)) AS UpdatedDate
FROM BSADB.dbo.DJ_Entity A WITH (NOLOCK)
JOIN BSADB.dbo.DJ_SanctionListReference B WITH (NOLOCK) ON A.EntityId = B.EntityId
WHERE A.Deceased = 1
  AND B.SanctionListReference LIKE '%Japanese Finance%'
  AND NOT EXISTS (SELECT 1 FROM #tempDJBlacklistJP X WHERE X.EntNum = A.EntityId)
GROUP BY A.EntityId, A.FullName;

-- 1.3 關聯地址、證件、生日與既有序號
;WITH TempAddress AS
(
    SELECT A.EntityId, A.Address, A.City, A.AddressCountry,
           ROW_NUMBER() OVER (PARTITION BY A.EntityId ORDER BY A.Id) AS RowId
    FROM BSADB.dbo.DJ_Address A WITH (NOLOCK)
    WHERE A.Deleted = 0
      AND EXISTS (SELECT 1 FROM #tempDJBlacklistJP X WHERE A.EntityId = X.EntNum)
),
TempIdent AS
(
    SELECT A.EntityId,
           CASE WHEN ISNULL(A.IdentificationType, '') = '' THEN NULL ELSE @OtherIdentMthCode END AS IdentificationType,
           A.IdentificationNumber,
           ROW_NUMBER() OVER (PARTITION BY A.EntityId ORDER BY A.Id) AS RowId
    FROM BSADB.dbo.DJ_IdentificationTypeInfo A WITH (NOLOCK)
    WHERE A.Deleted = 0
      AND EXISTS (SELECT 1 FROM #tempDJBlacklistJP X WHERE A.EntityId = X.EntNum)
),
TempDOB AS
(
    SELECT A.EntityId, A.InfoDay, A.InfoMonth, A.InfoYear,
           ROW_NUMBER() OVER (PARTITION BY A.EntityId ORDER BY A.Id) AS RowId
    FROM BSADB.dbo.DJ_DateTypeInfo A WITH (NOLOCK)
    WHERE A.DateType = 'Date of Birth'
      AND A.Deleted = 0
      AND EXISTS (SELECT 1 FROM #tempDJBlacklistJP X WHERE A.EntityId = X.EntNum)
),
TempNUM AS
(
    SELECT A.spec_name, A.updated_date, A.remark, A.ent_num
    FROM BSADBJP..OFAC_SPEC A WITH (NOLOCK)
    WHERE A.GROUPID = 5 AND A.DInd = 'N'
)
INSERT INTO #tempDJBlacklistDetailsJP (Num, EntNum, SdnName, UpdatedDate, Address, City, Country, IdentType, IdentNumber, DOB)
SELECT 
    E.ent_num,
    A.EntNum,
    A.SdnName,
    A.UpdatedDate,
    B.Address,
    LEFT(B.City, 100),
    LEFT(B.AddressCountry, 100),
    C.IdentificationType,
    LEFT(C.IdentificationNumber, 44),
    CASE 
        WHEN D.InfoDay IS NULL OR D.InfoMonth IS NULL 
        THEN D.InfoYear 
        ELSE CONVERT(VARCHAR(8), dbo.TryParseDate(D.InfoYear + ' ' + D.InfoMonth + ' ' + D.InfoDay), 112) 
    END
FROM #tempDJBlacklistJP A
LEFT JOIN TempAddress B ON A.EntNum = B.EntityId AND B.RowId = 1
LEFT JOIN TempIdent   C ON A.EntNum = C.EntityId AND C.RowId = 1
LEFT JOIN TempDOB     D ON A.EntNum = D.EntityId AND D.RowId = 1
LEFT JOIN TempNUM     E ON A.EntNum = E.remark AND A.SdnName = E.spec_name;

-- 1.4 為新增項目指派自增流水號
DECLARE @MAXNo INT;
SELECT @MAXNo = ISNULL(MAX(ent_num), 0) FROM BSADBJP..OFAC_SPEC;

UPDATE #tempDJBlacklistDetailsJP
SET @MAXNo = @MAXNo + 1,
    Num = @MAXNo
WHERE Num IS NULL;

CREATE CLUSTERED INDEX IX_TempJP_Key ON #tempDJBlacklistDetailsJP(SdnName, EntNum);


-- =====================================================================================
-- [STEP 2] 同步前預覽分析 (Dry-Run)
-- =====================================================================================
SELECT 
    CASE 
        WHEN T.spec_name IS NULL THEN '1. 即將新增 (Insert)'
        WHEN T.DInd = 'Y'        THEN '2. 即將重新啟用 (Reactivate)'
        WHEN S.UpdatedDate <> T.updated_date THEN '3. 即將更新資料 (Update)'
    END AS ActionPlan,
    COALESCE(S.EntNum, CAST(T.remark AS INT)) AS EntNum,
    COALESCE(S.SdnName, T.spec_name) AS SdnName,
    T.DInd AS Current_DInd,
    T.updated_date AS Internal_UpdatedDate,
    S.UpdatedDate  AS DJ_UpdatedDate
FROM #tempDJBlacklistDetailsJP S
FULL OUTER JOIN BSADBJP..OFAC_SPEC T WITH (NOLOCK)
    ON T.GROUPID = 5
   AND T.spec_name = S.SdnName 
   AND T.remark = CAST(S.EntNum AS VARCHAR(100))
WHERE (T.spec_name IS NULL)
   OR (S.EntNum IS NOT NULL AND T.DInd = 'Y')
   OR (S.EntNum IS NOT NULL AND T.DInd = 'N' AND S.UpdatedDate <> T.updated_date)

UNION ALL

SELECT 
    '4. 即將軟刪除 (Soft Delete)' AS ActionPlan,
    CAST(T.remark AS INT) AS EntNum,
    T.spec_name AS SdnName,
    T.DInd AS Current_DInd,
    T.updated_date AS Internal_UpdatedDate,
    NULL AS DJ_UpdatedDate
FROM BSADBJP..OFAC_SPEC T WITH (NOLOCK)
LEFT JOIN #tempDJBlacklistDetailsJP S
    ON T.spec_name = S.SdnName 
   AND T.remark = CAST(S.EntNum AS VARCHAR(100))
WHERE T.GROUPID = 5
  AND T.DInd = 'N'
  AND S.EntNum IS NULL;


-- =====================================================================================
-- [STEP 3] 核心 MERGE 同步作業
-- =====================================================================================
BEGIN TRANSACTION;

BEGIN TRY
    ;WITH TargetTable AS
    (
        SELECT *
        FROM BSADBJP..OFAC_SPEC
        WHERE GROUPID = 5
    )
    MERGE TargetTable AS T
    USING (
        SELECT Num, EntNum, SdnName, UpdatedDate, Address, City, Country, IdentType, IdentNumber, DOB 
        FROM #tempDJBlacklistDetailsJP
    ) AS S
    ON T.spec_name = S.SdnName 
   AND T.remark = CAST(S.EntNum AS VARCHAR(100))

    WHEN NOT MATCHED BY TARGET THEN
        INSERT (
            spec_name, updated_date, remark, TaxID, IDENT, IDENTO, TaxIDCD, IDNUM, IssBy, DInd,
            creUserID, STATE, ADDRESS, COUNTRY, GROUPID, SOURCE, EnterFlag, ApprovedBy, ApprovedDate,
            DelUserID, DelDate, ApproveDelUserID, ApproveDelDate, creDate,
            updated_date_UTC, ApprovedDate_UTC, DelDate_UTC, ApproveDelDate_UTC, creDate_UTC, ent_num, DOB
        )
        VALUES (
            S.SdnName, S.UpdatedDate, S.EntNum, '', S.IdentType, S.IdentNumber, '', '', 'JP', 'N',
            'System Admin', ISNULL(S.City, ''), S.Address, S.Country, '5', 'JP FINANCE', NULL,
            'System Admin', GETDATE(), NULL, NULL, NULL, NULL, GETDATE(),
            GETUTCDATE(), GETUTCDATE(), NULL, NULL, GETUTCDATE(), S.Num, S.DOB
        )

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
        CASE WHEN $ACTION IN ('INSERT') THEN Inserted.taxid ELSE Deleted.taxid END,
        CASE WHEN $ACTION IN ('INSERT') THEN Inserted.IDENT ELSE Deleted.IDENT END,
        CASE WHEN $ACTION IN ('INSERT') THEN Inserted.IDENTO ELSE Deleted.IDENTO END,
        CASE WHEN $ACTION IN ('INSERT') THEN Inserted.TaxIDCD ELSE Deleted.TaxIDCD END,
        CASE WHEN $ACTION IN ('INSERT') THEN Inserted.IDNUM ELSE Deleted.IDNUM END,
        CASE WHEN $ACTION IN ('INSERT') THEN Inserted.issby ELSE Deleted.issby END,
        CASE WHEN $ACTION IN ('INSERT') THEN Inserted.DInd ELSE Deleted.DInd END,
        CASE WHEN $ACTION IN ('INSERT') THEN Inserted.creUserID ELSE Deleted.creUserID END,
        'System Admin',
        GETUTCDATE(),
        CASE 
            WHEN $ACTION = 'INSERT' OR ($ACTION = 'UPDATE' AND Deleted.DInd = 'Y' AND Inserted.DInd = 'N') THEN '01'
            WHEN $ACTION = 'UPDATE' AND Inserted.DInd = 'Y' THEN '03'
            ELSE '02'
        END,
        CASE WHEN $ACTION IN ('INSERT') THEN Inserted.ADDRESS ELSE Deleted.ADDRESS END,
        CASE WHEN $ACTION IN ('INSERT') THEN Inserted.STATE ELSE Deleted.STATE END,
        CASE WHEN $ACTION IN ('INSERT') THEN Inserted.COUNTRY ELSE Deleted.COUNTRY END,
        CASE WHEN $ACTION IN ('INSERT') THEN Inserted.GROUPID ELSE Deleted.GROUPID END,
        CASE WHEN $ACTION IN ('INSERT') THEN Inserted.SOURCE ELSE Deleted.SOURCE END,
        CASE WHEN $ACTION IN ('INSERT') THEN Inserted.EnterFlag ELSE Deleted.EnterFlag END,
        CASE WHEN $ACTION IN ('INSERT') THEN Inserted.ApprovedBy ELSE Deleted.ApprovedBy END,
        CASE WHEN $ACTION IN ('INSERT') THEN Inserted.ApprovedDate ELSE Deleted.ApprovedDate END,
        CASE WHEN $ACTION IN ('INSERT') THEN Inserted.DelUserID ELSE Deleted.DelUserID END,
        CASE WHEN $ACTION IN ('INSERT') THEN Inserted.DelDate ELSE Deleted.DelDate END,
        CASE WHEN $ACTION IN ('INSERT') THEN Inserted.ApproveDelUserID ELSE Deleted.ApproveDelUserID END,
        CASE WHEN $ACTION IN ('INSERT') THEN Inserted.ApproveDelDate ELSE Deleted.ApproveDelDate END,
        CASE WHEN $ACTION IN ('INSERT') THEN GETUTCDATE() ELSE GETUTCDATE() END,
        CASE WHEN $ACTION IN ('INSERT') THEN Inserted.ApprovedDate_UTC ELSE Deleted.ApprovedDate_UTC END,
        CASE WHEN $ACTION IN ('INSERT') THEN Inserted.DelDate_UTC ELSE Deleted.DelDate_UTC END,
        CASE WHEN $ACTION IN ('INSERT') THEN Inserted.ApproveDelDate_UTC ELSE Deleted.ApproveDelDate_UTC END,
        CASE WHEN $ACTION IN ('INSERT') THEN Inserted.DOB ELSE Deleted.DOB END
    INTO BSADBJP.dbo.OFAC_SPEC_LOG
        (ent_num, spec_name, updated_date, remark, TaxID, IDENT, IDENTO, TaxIDCD, IDNUM, IssBy, DInd,
         creUserID, UserID, ActionDT, ActionCD, Address, State, Country, GROUPID, SOURCE, EnterFlag,
         ApprovedBy, ApprovedDate, DelUserID, DelDate, ApproveDelUserID, ApproveDelDate, ActionDT_UTC,
         ApprovedDate_UTC, DelDate_UTC, ApproveDelDate_UTC, DOB);

    COMMIT TRANSACTION;
    PRINT '日本金融制裁名單同步作業執行成功。';
END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0
        ROLLBACK TRANSACTION;

    PRINT '日本金融制裁名單同步作業發生錯誤，已復原交易。';
    THROW;
END CATCH;


-- =====================================================================================
-- [STEP 4] 清理暫存表
-- =====================================================================================
IF OBJECT_ID('tempdb..#tempDJBlacklistJP') IS NOT NULL DROP TABLE #tempDJBlacklistJP;
IF OBJECT_ID('tempdb..#tempDJBlacklistDetailsJP') IS NOT NULL DROP TABLE #tempDJBlacklistDetailsJP;
