CREATE PROC budget.CreateBudgetFile 
@Budget_FiscalYear INT 
AS 
--DECLARE @Budget_FiscalYear INT = 2024;
DECLARE @Current_FiscalYear INT = @Budget_FiscalYear - 1;
------------------------------------------------------------------------------------------------------
--STEP 1 Set up template for budget file
--One row per location per revenue date
------------------------------------------------------------------------------------------------------
--Current Year
IF OBJECT_ID('tempdb..#Calendar') IS NOT NULL
    DROP TABLE #Calendar;
SELECT Location_ID,
       LocationNumber,
       Location,
       l.Type AS LocationTypeID,
       lt.Name AS LocationType,
       YEAR(FiscalYear) FiscalYear,
       PeriodNumber,
       WeekofYear,
       PeriodDay,
       WeekDay,
       CONVERT(DATE, RevenueDate) [Date]
INTO #Calendar
FROM DEF_FiscalCalendar
    CROSS JOIN DEF_Location l
    INNER JOIN DEF_Location_Type lt
        ON l.Type = lt.LocationType_ID
WHERE YEAR(FiscalYear) = @Current_FiscalYear;
TRUNCATE TABLE Budget.RevenueBudget_Beta;
INSERT INTO Budget.RevenueBudget_Beta
(
    Location_ID,
    LocationNumber,
    Location,
    LocationTypeID,
    LocationType,
    FiscalYear,
    PeriodNumber,
    WeekofYear,
    PeriodDay,
    Date_CurrentYear,
    WeekDay,
    PeriodAmount,
    PeriodBudgetAmount,
    PercentAmount,
    RevenueAmount_CurrentYear,
    Date_BudgetYear,
    isHoliday,
    Holiday,
    HolidayFuture,
    isFlipped,
    RevenueUsed_CurrentYear,
    DailyBudget_BudgetYear,
    UpdateDate,
    RevenueUsed_CurrentYear_FNL,
    Notes,
    AdjustmentType
)
SELECT c.Location_ID,
       c.LocationNumber,
       c.Location,
       c.LocationTypeID,
       c.LocationType,
       c.FiscalYear,
       c.PeriodNumber,
       c.WeekofYear,
       c.PeriodDay,
       c.Date,
       c.WeekDay,
       NULL,
       NULL,
       NULL,
       NULL,
       NULL,
       NULL,
       NULL,
       NULL,
       NULL,
       NULL,
       NULL,
       GETDATE(),
       NULL,
       NULL,
       NULL
FROM #Calendar c;

--Budget Year
IF OBJECT_ID('tempdb..#Calendar_Future') IS NOT NULL
    DROP TABLE #Calendar_Future;
SELECT Location_ID,
       LocationNumber,
       Location,
       YEAR(FiscalYear) FiscalYear,
       PeriodNumber,
       WeekofYear,
       PeriodDay,
       CONVERT(DATE, RevenueDate) [Date]
INTO #Calendar_Future
FROM DEF_FiscalCalendar
    CROSS JOIN DEF_Location
WHERE YEAR(FiscalYear) = @Budget_FiscalYear;

UPDATE f
SET f.Date_BudgetYear = c.Date
FROM Budget.RevenueBudget_Beta f
    INNER JOIN #Calendar_Future c
        ON f.Location_ID = c.Location_ID
           AND f.PeriodNumber = c.PeriodNumber
           AND f.PeriodDay = c.PeriodDay;

------------------------------------------------------------------------------------------------------
--STEP 2 Prefill current year base with actual revenue (RevenueAmount_CY column) for each location
------------------------------------------------------------------------------------------------------
IF OBJECT_ID('tempdb..#BusRevenue') IS NOT NULL
    DROP TABLE #BusRevenue;
SELECT Location_ID,
       PeriodNumber,
       CONVERT(DATE, r.Date) revenuedate,
       SUM(ISNULL(Amount, 0.00)) Amount
INTO #BusRevenue
FROM Revenue r
    INNER JOIN RevenueSource rs
        ON r.RevenueSource_ID = rs.RevenueSource_ID
    INNER JOIN Employment e
        ON e.Employment_ID = rs.Employment_ID
    INNER JOIN DEF_FiscalCalendar cal
        ON CONVERT(DATE, cal.RevenueDate) = CONVERT(DATE, r.Date)
WHERE YEAR(FiscalYear) = @Current_FiscalYear
GROUP BY Location_ID,
         PeriodNumber,
         CONVERT(DATE, r.Date);
--Update budget file with actual revenue
UPDATE b
SET b.RevenueAmount_CurrentYear = CONVERT(NUMERIC(18, 4), r.Amount)
FROM [Budget].[RevenueBudget_Beta] b
    JOIN #BusRevenue r
        ON r.Location_ID = b.Location_ID
           AND CONVERT(DATE, r.revenuedate) = CONVERT(DATE, b.Date_CurrentYear);

------------------------------------------------------------------------------------------------------
--STEP 3 Prefill next year budget with PeriodBudget file provided by Finanace
------------------------------------------------------------------------------------------------------
/*
>>>TEMPLATE 1: Period Budget by Location by Period
1. Load Budget file uploaded by Finance into [Budget].[PeriodBudgetFile_Beta]
2. Insert pivoted data into [Budget].[TrendSchedule_Budget_Beta]
*/

IF OBJECT_ID('tempdb..#PeriodBudget') IS NOT NULL
    DROP TABLE #PeriodBudget;

SELECT LocationNumber,
       Period,
       unpvt.Budget
INTO #PeriodBudget
FROM
(
    SELECT CONVERT(INT, [LocationNumber]) LocationNumber,
           CONVERT(NUMERIC(18, 4), [1]) [1],
           CONVERT(NUMERIC(18, 4), [2]) [2],
           CONVERT(NUMERIC(18, 4), [3]) [3],
           CONVERT(NUMERIC(18, 4), [4]) [4],
           CONVERT(NUMERIC(18, 4), [5]) [5],
           CONVERT(NUMERIC(18, 4), [6]) [6],
           CONVERT(NUMERIC(18, 4), [7]) [7],
           CONVERT(NUMERIC(18, 4), [8]) [8],
           CONVERT(NUMERIC(18, 4), [9]) [9],
           CONVERT(NUMERIC(18, 4), [10]) [10],
           CONVERT(NUMERIC(18, 4), [11]) [11],
           CONVERT(NUMERIC(18, 4), [12]) [12]
    FROM [Budget].[PeriodBudgetFile_Beta]
) p
    UNPIVOT
    (
        Budget
        FOR Period IN ([1], [2], [3], [4], [5], [6], [7], [8], [9], [10], [11], [12])
    ) AS unpvt;
TRUNCATE TABLE Budget.[TrendSchedule_Budget_Beta];

INSERT INTO [Budget].[TrendSchedule_Budget_Beta]
(
    [FiscalYear],
    [PeriodNumber],
    [Location_ID],
    [Amount]
)
SELECT @Budget_FiscalYear FiscalYear,
       b.Period,
       l.Location_ID,
       b.Budget
FROM #PeriodBudget b
    LEFT JOIN dbo.DEF_Location l
        ON CONVERT(INT, b.LocationNumber) = l.LocationNumber;
--Update PeriodBudgetAmount
UPDATE d
SET d.PeriodBudgetAmount = p.Amount
FROM [Budget].[RevenueBudget_Beta] d
    JOIN [Budget].[TrendSchedule_Budget_Beta] p
        ON p.PeriodNumber = d.PeriodNumber
           AND p.Location_ID = d.Location_ID;

------------------------------------------------------------------------------------------------------
--STEP 4 Ad-hoc Adjustments made by Finance
------------------------------------------------------------------------------------------------------
/*
1. Holiday flipping
>>>TEMPLATE 3: Holiday Flipping will be provided by Finance
HolidayName	
HolidayDate_CurrentYear	
HolidayDate_BudgetYear
*/
UPDATE [Budget].[HolidayFlipping_Beta]
SET HolidayDate_CurrentYear = CONVERT(DATE, HolidayDate_CurrentYear),
    HolidayDate_BudgetYear = CONVERT(DATE, HolidayDate_BudgetYear);

--Update Holiday column
UPDATE b
SET b.isHoliday = 1,
    b.Holiday = h.HolidayName
FROM [Budget].[RevenueBudget_Beta] b
    JOIN [Budget].[HolidayFlipping_Beta] h
        ON CONVERT(DATE, b.Date_CurrentYear) = CONVERT(DATE, h.HolidayDate_CurrentYear);

--Update HolidayFuture column
UPDATE b
SET b.isHoliday = 1,
    b.HolidayFuture = h.HolidayName
FROM [Budget].[RevenueBudget_Beta] b
    JOIN [Budget].[HolidayFlipping_Beta] h
        ON CONVERT(DATE, b.Date_BudgetYear) = CONVERT(DATE, h.HolidayDate_BudgetYear);

--Don't flip holidays that fall on same days on both years
IF OBJECT_ID('tempdb..#DoNotFlip') IS NOT NULL
    DROP TABLE #DoNotFlip;
SELECT DISTINCT
       Holiday
INTO #DoNotFlip
FROM [Budget].[RevenueBudget_Beta]
WHERE isHoliday IS NOT NULL
      AND Holiday = HolidayFuture;
UPDATE [Budget].[RevenueBudget_Beta]
SET isFlipped = CONVERT(BIT, 0),
    Notes = 'No need to flip holidays that fall on the same day on both years'
WHERE Holiday IN
      (
          SELECT * FROM #DoNotFlip
      );

--Flipping
IF OBJECT_ID('tempdb..#HolidayFlipping') IS NOT NULL
    DROP TABLE #HolidayFlipping;

SELECT Location_ID,
       LocationNumber,
       Location,
       Date_CurrentYear,
       RevenueAmount_CurrentYear,
       Date_BudgetYear,
       Holiday,
       HolidayFuture
INTO #HolidayFlipping
FROM [Budget].[RevenueBudget_Beta]
WHERE ISNULL(isFlipped, 2) <> 0
      AND isHoliday = 1
ORDER BY Location_ID;

UPDATE b
SET b.RevenueUsed_CurrentYear = holi.RevenueAmount_CurrentYear,
    b.isFlipped = 1
FROM [Budget].[RevenueBudget_Beta] b
    JOIN
    (SELECT * FROM #HolidayFlipping WHERE HolidayFuture IS NOT NULL) holi
        ON b.Location_ID = holi.Location_ID
           AND b.Holiday = holi.HolidayFuture;

UPDATE b
SET b.RevenueUsed_CurrentYear = holi.RevenueAmount_CurrentYear,
    b.isFlipped = 1
FROM [Budget].[RevenueBudget_Beta] b
    JOIN
    (SELECT * FROM #HolidayFlipping WHERE Holiday IS NOT NULL) holi
        ON b.Location_ID = holi.Location_ID
           AND b.HolidayFuture = holi.Holiday;

/*Check results*/
--SELECT * FROM [Budget].[RevenueBudget_Beta] WHERE isHoliday = 1 AND ISNULL(isFlipped, 2) <> 0 ORDER BY Location_ID, Date_CurrentYear
--SELECT * FROM #HolidayFlipping ORDER BY Location_ID, Date_CurrentYear

/*
2. Change in revenue base (including PreAcquisition data)
>>>TEMPLATE 2: Revenue base by Location by Date 
LocationNumber	
RevenueDate_CurrentYear	
AdjustedBase_CurrentYear
*/
--PreAcquisition data should come from file uploaded by Finance
--File cleanup
DELETE [Budget].[RevenueBaseAdj_Beta]
WHERE AdjustedBase_CurrentYear = '';
UPDATE [Budget].[RevenueBaseAdj_Beta]
SET AdjustedBase_CurrentYear = CONVERT(NUMERIC(18, 4), AdjustedBase_CurrentYear),
    RevenueDate_CurrentYear = CONVERT(DATE, RevenueDate_CurrentYear),
    LocationNumber = CONVERT(INT, LocationNumber);

--Update RevenueUsed_CurrentYear with PreAcquisition data for new acquisitions
UPDATE b
SET b.RevenueUsed_CurrentYear = CONVERT(NUMERIC(18, 4), r.AdjustedBase_CurrentYear)
FROM [Budget].[RevenueBudget_Beta] b
    JOIN [Budget].[RevenueBaseAdj_Beta] r
        ON CONVERT(DATE, b.Date_CurrentYear) = CONVERT(DATE, r.RevenueDate_CurrentYear)
           AND r.LocationNumber = b.LocationNumber;
------------------------------------------------------------------------------------------------------
--STEP 5 Calculated fileds
------------------------------------------------------------------------------------------------------
/*
RevenueUsed_CurrentYear_FNL
PeriodAmount = SUM(NetRevenue) per loc per period
PercentAmount = PeriodBudgetAmount/PeriodAmount
DailyBudget_BudgetYear
*/
/*RevenueUsed_CurrentYear_FNL*/
UPDATE [Budget].[RevenueBudget_Beta]
SET RevenueUsed_CurrentYear_FNL = CASE
                                      WHEN RevenueUsed_CurrentYear IS NOT NULL THEN
                                          ISNULL(RevenueUsed_CurrentYear, 0)
                                      ELSE
                                          ISNULL(RevenueAmount_CurrentYear, 0)
                                  END;
/*Check results*/
--SELECT *
--FROM [Budget].[RevenueBudget_Beta]
--WHERE ISNULL(isFlipped, 2) = 1
--      AND Date_CurrentYear <= CONVERT(DATE, GETDATE())
--ORDER BY Location_ID,
--         Date_CurrentYear;

/*PeriodAmount*/
IF OBJECT_ID('tempdb..#SumRevAmount') IS NOT NULL
    DROP TABLE #SumRevAmount;

SELECT Location_ID,
       LocationNumber,
       PeriodNumber,
       ISNULL(SUM(RevenueAmount_CurrentYear), 0) PeriodAmount
INTO #SumRevAmount
FROM [Budget].[RevenueBudget_Beta]
WHERE CONVERT(DATE, Date_CurrentYear) < CONVERT(DATE, GETDATE())
GROUP BY PeriodNumber,
         Location_ID,
         LocationNumber
ORDER BY Location_ID,
         PeriodNumber;

UPDATE b
SET b.PeriodAmount = p.PeriodAmount
FROM [Budget].[RevenueBudget_Beta] b
    JOIN #SumRevAmount p
        ON b.Location_ID = p.Location_ID
           AND p.PeriodNumber = b.PeriodNumber;

/*Check results*/
--SELECT *
--FROM [Budget].[RevenueBudget_Beta]
--WHERE Date_CurrentYear <= CONVERT(DATE, GETDATE())
--ORDER BY Location_ID,
--         Date_CurrentYear;

/*PercentAmount*/
UPDATE [Budget].[RevenueBudget_Beta]
SET PercentAmount = CONVERT(NUMERIC(18, 4), PeriodBudgetAmount / NULLIF(PeriodAmount, 0));
/*Check results*/
--SELECT *
--FROM [Budget].[RevenueBudget_Beta]
--WHERE Date_CurrentYear <= CONVERT(DATE, GETDATE())
--ORDER BY Location_ID,
--         Date_CurrentYear;

/*DailyBudget_BudgetYear*/
UPDATE [Budget].[RevenueBudget_Beta]
SET DailyBudget_BudgetYear = CONVERT(NUMERIC(18, 4), RevenueUsed_CurrentYear_FNL * PercentAmount);
/*Check results*/
SELECT *
FROM [Budget].[RevenueBudget_Beta]
WHERE Date_CurrentYear <= CONVERT(DATE, GETDATE())
ORDER BY Location_ID,
         Date_CurrentYear;

