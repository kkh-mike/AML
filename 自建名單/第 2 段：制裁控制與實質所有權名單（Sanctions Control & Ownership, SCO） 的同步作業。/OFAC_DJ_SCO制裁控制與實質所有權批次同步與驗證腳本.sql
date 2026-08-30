/*
========================================================================================
腳本名稱：OFAC_DJ_SCO制裁控制與實質所有權批次同步與驗證腳本.sql
主要定位：第 2 段 SCO (Sanctions Control & Ownership) 資料同步與維護 (固定 GROUPID = 27)
目標主表：BSADB.dbo.OFAC_GLSpec
稽核日誌：BSADB.dbo.OFAC_GLSpec_Log

[適用對象]
系統維運人員、DBA

[使用時機]
1. 第 2 段 SCO 排程失敗，需手動補跑時。
2. 需預覽本次 SCO 變更筆數 (Dry-Run) 時。

[核心邏輯說明]
- 篩選 OFAC/EU 股權大於 50% (Majority Owned) 或具控制力 (Control) 的實體名單。
- 排除 NameSubType = 'OSN'。
- ADDRESS 欄位改放彙整自 DJ_SanctionListReference 的參考清單 (超過 400 字則填固定提示)。
========================================================================================
*/

-- =====================================================================================
-- [STEP 1] 來源資料清洗與暫存
-- =====================================================================================
IF OBJECT_ID('tempdb..#tempDJBlacklistSCO') IS NOT NULL
    DROP TABLE #tempDJBlacklistSCO;

IF OBJECT_ID('tempdb..#tempDJBlacklistDetailsSCO') IS NOT NULL
    DROP TABLE #tempDJBlacklistDetailsSCO;

IF OBJECT_ID('tempdb..#DJ_SanctionListReference') IS NOT NULL
    DROP TABLE #DJ_SanctionListReference;

CREATE TABLE #tempDJBlacklistSCO (
    EntNum      INT NOT NULL, 
    SdnName     NVARCHAR(350) NOT NULL, 
    UpdatedDate VARCHAR(8) NOT NULL
);

CREATE TABLE #tempDJBlacklistDetailsSCO (
    EntNum       INT NOT NULL, 
    SdnName      NVARCHAR(350) NOT NULL, 
    UpdatedDate  VARCHAR(8) NOT NULL, 
    Address      NVARCHAR(400), 
    City         NVARCHAR(200), 
    Country      NVARCHAR(100), 
    IdentType    VARCHAR(2), 
    IdentNumber  NVARCHAR(44), 
    DOB          VARCHAR(8)
);

-- 1.1 篩選 OFAC/EU 股權大於 50% 或具控制力的活躍實體
INSERT INTO #tempDJBlacklistSCO (EntNum, SdnName, UpdatedDate)
SELECT  
    C.EntNum, 
    C.SdnName, 
    MAX(C.UpdatedDate) AS UpdatedDate 
FROM BSADB.dbo.DJ_Entity A WITH (NOLOCK)
JOIN BSADB.dbo.DJ_ListCategory B WITH (NOLOCK) ON A.EntityId = B.EntityId
JOIN BSADB.dbo.DJ_List_Data_A C WITH (NOLOCK)  ON A.EntityId = C.EntNum
LEFT JOIN BSADB.dbo.DJ_AltName D WITH (NOLOCK) ON C.EntNum = D.EntityId AND C.AltNum = D.AltNameId
WHERE A.PersonStatus <> 'Inactive' 
  AND B.Description3 IN (
    'OFAC Related - Majority Owned',
    'OFAC Related – Control',
    'OFAC - Regional Sanctions Related - Majority Owned',
    'OFAC - Regional Sanctions Related - Control',
    'EU Related - Majority Owned',
    'EU Related - Control',
    'EU - Regional Sanctions Related - Majority Owned',
    'EU - Regional Sanctions Related – Control'
  ) 
  AND ISNULL(D.NameSubType, '') <> 'OSN'
  AND B.Deleted = 0
GROUP BY C.EntNum, C.SdnName;

-- 1.2 彙整制裁清單參考資訊 (SanctionListReference)
SELECT  
    T.EntityId,
    STUFF((
        SELECT ';' + t2.SanctionListReference
        FROM BSADB.dbo.DJ_SanctionListReference t2 WITH (NOLOCK)
        WHERE t2.EntityId = T.EntityId
        FOR XML PATH(''), TYPE
    ).value('.', 'nvarchar(max)'), 1, 1, '') AS SanctionListReference
INTO #DJ_SanctionListReference
FROM BSADB.dbo.DJ_SanctionListReference T WITH (NOLOCK)
GROUP BY T.EntityId;

UPDATE #DJ_SanctionListReference
SET SanctionListReference = 'Visit the Dow Jones for further information'
WHERE LEN(SanctionListReference) >= 400;

-- 1.3 組裝明細資料 (Address 填入制裁參考資訊)
;WITH TempRef AS (
    SELECT 
        A.EntityId, 
        A.SanctionListReference, 
        ROW_NUMBER() OVER(PARTITION BY A.EntityId ORDER BY A.EntityId) AS RowId
    FROM #DJ_SanctionListReference A
    WHERE EXISTS (SELECT 1 FROM #tempDJBlacklistSCO X WHERE A.EntityId = X.EntNum)
)
INSERT INTO #tempDJBlacklistDetailsSCO (EntNum, SdnName, UpdatedDate, Address)
SELECT 
    A.EntNum, 
    A.SdnName, 
    A.UpdatedDate, 
    B.SanctionListReference
FROM #tempDJBlacklistSCO A 
LEFT JOIN TempRef B ON A.EntNum = B.EntityId AND B.RowId = 1;

CREATE CLUSTERED INDEX IX_TempSCO_Key ON #tempDJBlacklistDetailsSCO(SdnName, EntNum);


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
FROM #tempDJBlacklistDetailsSCO S
FULL OUTER JOIN BSADB.dbo.OFAC_GLSpec T WITH (NOLOCK)
    ON T.GROUPID = 27
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
FROM BSADB.dbo.OFAC_GLSpec T WITH (NOLOCK)
LEFT JOIN #tempDJBlacklistDetailsSCO S
    ON T.spec_name = S.SdnName 
   AND T.remark = CAST(S.EntNum AS VARCHAR(100))
WHERE T.GROUPID = 27
  AND T.EnterFlag = 'D'
  AND T.DInd = 'N'
  AND S.EntNum IS NULL;


-- =====================================================================================
-- [STEP 3] 核心 MERGE 同步作業
-- =====================================================================================
BEGIN TRANSACTION;

BEGIN TRY
    ;WITH TargetTable AS (
        SELECT 
            A.spec_name, A.updated_date, A.remark, A.TaxID, A.IDENT, A.IDENTO, A.TaxIDCD, A.IDNUM, A.IssBy, A.DInd, A.creUserID, A.STATE, A.ADDRESS, A.COUNTRY,
            A.GROUPID, A.SOURCE, A.EnterFlag, A.ApprovedBy, A.ApprovedDate, A.DelUserID, A.DelDate, A.ApproveDelUserID, A.ApproveDelDate, A.creDate,
            A.updated_date_UTC, A.ApprovedDate_UTC, A.DelDate_UTC, A.ApproveDelDate_UTC, A.creDate_UTC, A.ent_num, A.DOB
        FROM BSADB.dbo.OFAC_GLSpec A 
        WHERE A.GROUPID = 27
    )
    MERGE TargetTable AS T
    USING (
        SELECT EntNum, SdnName, UpdatedDate, Address, City, Country, IdentType, IdentNumber, DOB 
        FROM #tempDJBlacklistDetailsSCO
    ) AS S
    ON T.spec_name = S.SdnName 
   AND T.remark = CAST(S.EntNum AS VARCHAR(100))

    WHEN NOT MATCHED BY TARGET THEN
        INSERT (spec_name, updated_date, remark, TaxID, IDENT, IDENTO, TaxIDCD, IDNUM, IssBy, DInd,
                creUserID, STATE, ADDRESS, COUNTRY, GROUPID, SOURCE, EnterFlag, ApprovedBy, ApprovedDate, DelUserID,
                DelDate, ApproveDelUserID, ApproveDelDate, creDate, updated_date_UTC, ApprovedDate_UTC, DelDate_UTC, ApproveDelDate_UTC, creDate_UTC,
                DOB)
        VALUES (S.SdnName, S.UpdatedDate, S.EntNum, '', S.IdentType, S.IdentNumber, '', '', '', 'N', 
                'System Admin', ISNULL(S.City, ''), S.Address, S.Country, '27', 'Sanctions Control Ownership', 'D', 'System Admin', GETDATE(), NULL, 
                NULL, NULL, NULL, GETDATE(), GETUTCDATE(), GETUTCDATE(), NULL, NULL, GETUTCDATE(),
                S.DOB)

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
    INTO BSADB.dbo.OFAC_GLSpec_Log (
        ent_num, spec_name, updated_date, remark, DInd, creUserID, IDENTO, STATE, ADDRESS, COUNTRY, GROUPID,
        IDENT, IDNUM, DOB, EnterFlag, ApprovedBy, ApprovedDate, DelUserID, DelDate, ApproveDelUserID,
        ApproveDelDate, CreationDate, updated_date_UTC, ApprovedDate_UTC, DelDate_UTC, ApproveDelDate_UTC,
        CreationDate_UTC, ActionCD, ActionDt
    );

    COMMIT TRANSACTION;
    PRINT 'SCO 制裁名單同步作業執行成功。';
END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0
        ROLLBACK TRANSACTION;

    PRINT 'SCO 制裁名單同步作業發生錯誤，已復原交易。';
    THROW;
END CATCH;


-- =====================================================================================
-- [STEP 4] 清理暫存表
-- =====================================================================================
IF OBJECT_ID('tempdb..#tempDJBlacklistSCO') IS NOT NULL DROP TABLE #tempDJBlacklistSCO;
IF OBJECT_ID('tempdb..#tempDJBlacklistDetailsSCO') IS NOT NULL DROP TABLE #tempDJBlacklistDetailsSCO;
IF OBJECT_ID('tempdb..#DJ_SanctionListReference') IS NOT NULL DROP TABLE #DJ_SanctionListReference;
