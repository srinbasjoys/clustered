-- =============================================================================
-- V1__init_cdc.sql
-- Runs automatically on first SQL Server container start.
-- Creates database, enables CDC, creates tables and users.
-- =============================================================================

-- Create database
IF NOT EXISTS (SELECT 1 FROM sys.databases WHERE name = 'YourDatabase')
BEGIN
    CREATE DATABASE YourDatabase;
    PRINT 'Database YourDatabase created.';
END
GO

USE YourDatabase;
GO

-- Enable CDC on the database
IF NOT EXISTS (
    SELECT 1 FROM sys.databases WHERE name = 'YourDatabase' AND is_cdc_enabled = 1
)
BEGIN
    EXEC sys.sp_cdc_enable_db;
    PRINT 'CDC enabled on database.';
END
GO

-- Create profiles table
IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'profiles' AND schema_id = SCHEMA_ID('dbo'))
BEGIN
    CREATE TABLE dbo.profiles (
        id         INT IDENTITY(1,1) PRIMARY KEY,
        name       NVARCHAR(255) NOT NULL,
        email      NVARCHAR(255) NOT NULL UNIQUE,
        bio        NVARCHAR(MAX) NULL,
        status     NVARCHAR(50)  NOT NULL DEFAULT 'active',
        created_at DATETIME2     NOT NULL DEFAULT SYSUTCDATETIME(),
        updated_at DATETIME2     NOT NULL DEFAULT SYSUTCDATETIME()
    );
    PRINT 'Table dbo.profiles created.';

    -- Enable CDC on profiles
    EXEC sys.sp_cdc_enable_table
        @source_schema       = N'dbo',
        @source_name         = N'profiles',
        @role_name           = NULL,
        @supports_net_changes = 1;
    PRINT 'CDC enabled on dbo.profiles.';
END
GO

-- Create users table
IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'users' AND schema_id = SCHEMA_ID('dbo'))
BEGIN
    CREATE TABLE dbo.users (
        id         INT IDENTITY(1,1) PRIMARY KEY,
        username   NVARCHAR(100) NOT NULL UNIQUE,
        email      NVARCHAR(255) NOT NULL UNIQUE,
        role       NVARCHAR(50)  NOT NULL DEFAULT 'user',
        active     BIT           NOT NULL DEFAULT 1,
        created_at DATETIME2     NOT NULL DEFAULT SYSUTCDATETIME()
    );
    PRINT 'Table dbo.users created.';

    EXEC sys.sp_cdc_enable_table
        @source_schema       = N'dbo',
        @source_name         = N'users',
        @role_name           = NULL,
        @supports_net_changes = 1;
    PRINT 'CDC enabled on dbo.users.';
END
GO

-- Verify
SELECT
    t.name            AS table_name,
    ct.capture_instance,
    ct.start_lsn
FROM sys.tables t
LEFT JOIN cdc.change_tables ct ON ct.source_object_id = t.object_id
WHERE t.name IN ('profiles', 'users');
GO

PRINT 'SQL Server init complete.';
GO
