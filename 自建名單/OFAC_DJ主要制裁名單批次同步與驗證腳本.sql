-- 中文命名：OFAC_DJ主要制裁名單批次同步與驗證腳本.sql

-- 英文命名：Sync_DJ_Primary_To_OFAC_GLSpec.sql



/*
========================================================================================
腳本名稱：OFAC_DJ主要制裁名單批次同步與驗證腳本.sql
主要定位：資料寫入與批次同步執行檔 (含資料異動交易)
目標主表：BSADB.dbo.OFAC_GLSpec
稽核日誌：BSADB.dbo.OFAC_GLSpec_Log

[適用對象]
系統維運人員、DBA

[使用時機]
1. 排程同步失敗，需進行人工手動補跑時。
2. 需要預先檢視全量名單變更筆數 (Dry-Run) 時。
3. 需要手動批次重整主表狀態時。

[核心功能與作業區塊]
- STEP 0：環境變數與外部證件代碼定義 (@GroupId 控制)。
- STEP 1：全量資料清洗與暫存 (抓取 DJ Primary Name、最新地址、第一筆證件與生日)。
- STEP 2：同步前預覽分析 (Dry-Run：新增、重新啟用、欄位更新、軟刪除)。
- STEP 3：核心 MERGE 同步作業 (主表寫入，並透過 OUTPUT 自動記錄至 Log 表)。
- STEP 4：同步後結果稽核與暫存表清理。

[注意事項]
本腳本包含交易寫入 (BEGIN TRANSACTION / MERGE)，執行 STEP 3 會正式異動資料，
執行前請務必確認 @GroupId 設定正確。
========================================================================================
*/



-- =====================================================================================
-- [STEP 0] 環境變數與前置代碼定義
-- =====================================================================================
DECLARE @GroupId BIGINT = 1; -- 指定比對與同步的 GroupId

-- 取得外部其他證件類型代碼
DECLARE @OtherIdentMthCode VARCHAR(2);
SELECT @OtherIdentMthCode = IDENTCODE 
FROM dbo.IDENTMTHD_DIM 
WHERE OTHIND = 'Y';


-- =====================================================================================
-- [STEP 1] 來源資料清洗與暫存
-- 彙整 Dow Jones 主要受制裁人名、最新地址、第一筆證件及出生日期
-- =====================================================================================
IF OBJECT_ID('tempdb..#SourceDJ') IS NOT NULL DROP TABLE #SourceDJ;

;WITH DJ_Primary AS
(
    -- 1. 篩選主要受制裁人名 (Primary Name)
    SELECT 
        A.EntNum, 
        A.SdnName, 
        MAX(A.UpdatedDate) AS UpdatedDate
    FROM BSADB.dbo.DJ_List_Data_A A WITH (NOLOCK)
    WHERE A.NamePropertyBitCode & 1 > 0
    GROUP BY A.EntNum, A.SdnName
),
TempAddress AS
(
    -- 2. 地址資訊 (僅取第 1 筆有效資料)
    SELECT 
        A.EntityId, A.Address, A.City, A.AddressCountry,
        ROW_NUMBER() OVER (PARTITION BY A.EntityId ORDER BY A.Id) AS RowId
    FROM BSADB.dbo.DJ_Address A WITH (NOLOCK)
    WHERE A.Deleted = 0
),
TempIdent AS
(
    -- 3. 證件資訊 (僅取第 1 筆有效資料)
    SELECT 
        A.EntityId,
        CASE WHEN ISNULL(A.IdentificationType, '') = '' THEN NULL ELSE @OtherIdentMthCode END AS IdentificationType,
        A.IdentificationNumber,
        ROW_NUMBER() OVER (PARTITION BY A.EntityId ORDER BY A.Id) AS RowId
    FROM BSADB.dbo.DJ_IdentificationTypeInfo A WITH (NOLOCK)
    WHERE A.Deleted = 0
),
TempDOB AS
(
    -- 4. 出生日期 (僅取第 1 筆有效資料)
    SELECT 
        A.EntityId, A.InfoDay, A.InfoMonth, A.InfoYear,
        ROW_NUMBER() OVER (PARTITION BY A.EntityId ORDER BY A.Id) AS RowId
    FROM BSADB.dbo.DJ_DateTypeInfo A WITH (NOLOCK)
    WHERE A.DateType = 'Date of Birth'
      AND A.Deleted = 0
)
SELECT 
    A.EntNum,
    A.SdnName,
    A.UpdatedDate,
    B.Address,
    LEFT(B.City, 100) AS City,
    LEFT(B.AddressCountry, 100) AS Country,
    C.IdentificationType AS IdentType,
    LEFT(C.IdentificationNumber, 44) AS IdentNumber,
    CASE 
        WHEN D.InfoDay IS NULL OR D.InfoMonth IS NULL 
        THEN D.InfoYear 
        ELSE CONVERT(VARCHAR(8), dbo.TryParseDate(D.InfoYear + ' ' + D.InfoMonth + ' ' + D.InfoDay), 112) 
    END AS DOB
INTO #SourceDJ
FROM DJ_Primary A
LEFT JOIN TempAddress B ON A.EntNum = B.EntityId AND B.RowId = 1
LEFT JOIN TempIdent   C ON A.EntNum = C.EntityId AND C.RowId = 1
LEFT JOIN TempDOB     D ON A.EntNum = D.EntityId AND D.RowId = 1;

-- 建立叢集索引加速比對
CREATE CLUSTERED INDEX IX_SourceDJ_Key ON #SourceDJ(SdnName, EntNum);


-- =====================================================================================
-- [STEP 2] 同步前預覽分析 (Dry-Run)
-- 實際執行同步前，可單獨執行此區段確認預計變更筆數
-- =====================================================================================

-- 2.1 匯總預覽：即將新增、重新啟用、更新資料的名單
SELECT 
    CASE 
        WHEN T.spec_name IS NULL THEN '1. 即將新增 (Insert)'
        WHEN T.DInd = 'Y'        THEN '2. 即將重新啟用 (Reactivate)'
        WHEN S.UpdatedDate <> T.updated_date THEN '3. 即將更新資料 (Update)'
    END AS ActionPlan,
    COALESCE(S.EntNum, CAST(T.remark AS BIGINT)) AS EntNum,
    COALESCE(S.SdnName, T.spec_name) AS SdnName,
    T.DInd AS Current_DInd,
    T.updated_date AS Internal_UpdatedDate,
    S.UpdatedDate  AS DJ_UpdatedDate
FROM #SourceDJ S
FULL OUTER JOIN BSADB.dbo.OFAC_GLSpec T 
    ON T.GROUPID = @GroupId
   AND T.spec_name = S.SdnName 
   AND T.remark = CAST(S.EntNum AS VARCHAR(100))
WHERE (T.spec_name IS NULL)
   OR (S.EntNum IS NOT NULL AND T.DInd = 'Y')
   OR (S.EntNum IS NOT NULL AND T.DInd = 'N' AND S.UpdatedDate <> T.updated_date);

-- 2.2 預覽即將軟刪除 (停用) 名單 (內部有效 DInd='N' 但 DJ 已除名)
SELECT 
    '4. 即將軟刪除 (Soft Delete)' AS ActionPlan,
    CAST(T.remark AS BIGINT) AS EntNum,
    T.spec_name AS SdnName,
    T.DInd AS Current_DInd,
    T.updated_date AS Internal_UpdatedDate,
    NULL AS DJ_UpdatedDate
FROM BSADB.dbo.OFAC_GLSpec T
LEFT JOIN #SourceDJ S 
    ON T.spec_name = S.SdnName 
   AND T.remark = CAST(S.EntNum AS VARCHAR(100))
WHERE T.GROUPID = @GroupId
  AND T.EnterFlag = 'D'
  AND T.DInd = 'N' 
  AND S.EntNum IS NULL;


-- =====================================================================================
-- [STEP 3] 核心 MERGE 同步作業
-- 執行主表異動並透過 OUTPUT 寫入稽核歷程至 OFAC_GLSpec_Log
-- =====================================================================================
BEGIN TRANSACTION;

BEGIN TRY
    MERGE INTO BSADB.dbo.OFAC_GLSpec AS T
    USING #SourceDJ AS S
       ON T.GROUPID = @GroupId
      AND T.spec_name = S.SdnName
      AND T.remark = CAST(S.EntNum AS VARCHAR(100))

    -- 情境 3：資料修改 / 重新啟用
    WHEN MATCHED AND (T.DInd = 'Y' OR S.UpdatedDate <> T.updated_date) THEN
        UPDATE SET 
            T.ADDRESS       = S.Address,
            T.CITY          = S.City,
            T.COUNTRY       = S.Country,
            T.IDTYPE        = S.IdentType,
            T.IDNUM         = S.IdentNumber,
            T.DOB           = S.DOB,
            T.updated_date  = S.UpdatedDate,
            T.updUserID     = 'System Admin',
            T.updDt         = GETDATE(),
            T.DInd          = 'N',
            T.delUserID     = CASE WHEN T.DInd = 'Y' THEN NULL ELSE T.delUserID END,
            T.delDt         = CASE WHEN T.DInd = 'Y' THEN NULL ELSE T.delDt END

    -- 情境 1：新增
    WHEN NOT MATCHED BY TARGET THEN
        INSERT (
            GROUPID, spec_name, remark, EnterFlag, DInd,
            ADDRESS, CITY, COUNTRY, IDTYPE, IDNUM, DOB,
            updated_date, creUserID, creDt
        )
        VALUES (
            @GroupId, S.SdnName, CAST(S.EntNum AS VARCHAR(100)), 'D', 'N',
            S.Address, S.City, S.Country, S.IdentType, S.IdentNumber, S.DOB,
            S.UpdatedDate, 'System Admin', GETDATE()
        )

    -- 情境 2：停用 / 軟刪除
    WHEN NOT MATCHED BY SOURCE 
     AND T.GROUPID = @GroupId 
     AND T.EnterFlag = 'D' 
     AND T.DInd = 'N' THEN
        UPDATE SET 
            T.DInd      = 'Y',
            T.delUserID = 'System Admin',
            T.delDt     = GETDATE()

    -- 記錄稽核歷程至 Log 表
    OUTPUT 
        GETDATE() AS ActionDt,
        CASE 
            WHEN $action = 'INSERT' THEN '01'
            WHEN $action = 'UPDATE' AND inserted.DInd = 'N' AND deleted.DInd = 'Y' THEN '01'
            WHEN $action = 'UPDATE' AND inserted.DInd = 'Y' AND deleted.DInd = 'N' THEN '03'
            ELSE '02'
        END AS ActionCD,
        inserted.ent_num,
        inserted.spec_name,
        inserted.remark,
        inserted.EnterFlag,
        inserted.GROUPID,
        inserted.DInd,
        inserted.updated_date
    INTO BSADB.dbo.OFAC_GLSpec_Log (
        ActionDt, ActionCD, ent_num, spec_name, remark, 
        EnterFlag, GROUPID, DInd, updated_date
    );

    COMMIT TRANSACTION;
    PRINT 'DJ 同步作業執行成功。';
END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0
        ROLLBACK TRANSACTION;

    PRINT 'DJ 同步作業發生錯誤，已復原交易。';
    THROW;
END CATCH;


-- =====================================================================================
-- [STEP 4] 同步後結果稽核與驗證
-- =====================================================================================

-- 4.1 檢視最新寫入 Log 的異動清單
SELECT 
    ActionDt,
    CASE ActionCD 
        WHEN '01' THEN '新增 / 重新啟用'
        WHEN '02' THEN '資料更新'
        WHEN '03' THEN '軟刪除 (停用)'
    END AS ActionType,
    ent_num,
    spec_name,
    remark AS DJ_EntNum,
    DInd,
    updated_date
FROM BSADB.dbo.OFAC_GLSpec_Log
WHERE EnterFlag = 'D'
  AND GROUPID = @GroupId
ORDER BY ActionDt DESC;

-- 4.2 清理暫存表
IF OBJECT_ID('tempdb..#SourceDJ') IS NOT NULL DROP TABLE #SourceDJ;
