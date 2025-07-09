const express = require('express');
const { Pool } = require('pg');
const cors = require('cors');
require('dotenv').config();

const app = express();
const port = process.env.PORT || 3697;

// PostgreSQL connection
const pool = new Pool({
    user: process.env.DB_USER || 'postgres',
    host: process.env.DB_HOST || 'postgres',
    database: process.env.DB_NAME || 'onboarding_system',
    password: process.env.DB_PASSWORD || 'admin321',
    port: process.env.DB_PORT || 5432,
});

// Test database connection
pool.query('SELECT NOW()', (err, res) => {
    if (err) {
        console.error('Database connection error:', err.stack);
    } else {
        console.log('Database connected at:', res.rows[0].now);
    }
});

app.use(cors());
app.use(express.json({ limit: '10mb' }));
app.use(express.urlencoded({ extended: true }));

// Enhanced error handler
const errorHandler = (err, req, res, next) => {
    console.error('Error stack:', err.stack);
    res.status(500).json({ 
        error: 'Internal Server Error',
        message: err.message,
        details: process.env.NODE_ENV === 'development' ? err.stack : undefined
    });
};

// Calculate onboarding progress
const calculateProgress = (employeeData) => {
    const totalSections = 5;
    let completedSections = 0;

    // Check personal details
    if (employeeData.first_name && employeeData.email) completedSections++;

    // Check education details
    if (employeeData.educational_details && employeeData.educational_details.length > 0) {
        completedSections++;
    }

    // Check bank details
    if (employeeData.bank_details) completedSections++;

    // Check ID uploads
    if (employeeData.id_uploads) completedSections++;

    // Check employment (either fresher or has previous employment)
    if (employeeData.is_fresher || 
        (employeeData.previous_company && employeeData.previous_company.length > 0)) {
        completedSections++;
    }

    return Math.round((completedSections / totalSections) * 100);
};

// Create new employee
app.post('/api/employees', async (req, res, next) => {
    const client = await pool.connect();
    try {
        await client.query('BEGIN');
        
        const {
            firstName, lastName, email, phone,
            guardianName, guardianPhone, dateOfBirth,
            gender, maritalStatus, isFresher,
            educationDetails, bankDetails, idUploads, previousCompany
        } = req.body;

        // Insert employee
        const employeeQuery = `
            INSERT INTO employees (
                first_name, last_name, email, phone,
                guardian_name, guardian_phone, date_of_birth,
                gender, marital_status, is_fresher
            ) VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10)
            RETURNING *`;
        
        const employeeValues = [
            firstName, lastName, email, phone,
            guardianName, guardianPhone, dateOfBirth,
            gender, maritalStatus, isFresher
        ];

        const employeeResult = await client.query(employeeQuery, employeeValues);
        const employee = employeeResult.rows[0];

        // Insert education details
        if (educationDetails && educationDetails.length > 0) {
            for (const edu of educationDetails) {
                const eduQuery = `
                    INSERT INTO education_details (
                        employee_id, education_type, institution_name,
                        branch, passout_year, percentage, location,
                        certificate_filename, certificate_data, certificate_type
                    ) VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10)`;
                
                const eduValues = [
                    employee.id, edu.educationType, edu.institutionName,
                    edu.branch, edu.passoutYear, edu.percentage, edu.location,
                    edu.certificate?.name, edu.certificate?.data, edu.certificate?.type
                ];

                await client.query(eduQuery, eduValues);
            }
        }

        // Insert bank details
        if (bankDetails) {
            const bankQuery = `
                INSERT INTO bank_details (
                    employee_id, account_holder_name, bank_name,
                    account_number, branch, ifsc_code,
                    location, pin_code
                ) VALUES ($1, $2, $3, $4, $5, $6, $7, $8)`;
            
            const bankValues = [
                employee.id, bankDetails.accountHolder, bankDetails.bankName,
                bankDetails.accountNumber, bankDetails.bankBranch, bankDetails.ifscCode,
                bankDetails.bankLocation, bankDetails.pinCode
            ];

            await client.query(bankQuery, bankValues);
        }

        // Insert ID uploads
        if (idUploads) {
            const idQuery = `
                INSERT INTO id_uploads (
                    employee_id,
                    pan_card_filename, pan_card_data, pan_card_type,
                    aadhar_card_filename, aadhar_card_data, aadhar_card_type,
                    passport_filename, passport_data, passport_type
                ) VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10)`;
            
            const idValues = [
                employee.id,
                idUploads.panCard?.name, idUploads.panCard?.data, idUploads.panCard?.type,
                idUploads.aadharCard?.name, idUploads.aadharCard?.data, idUploads.aadharCard?.type,
                idUploads.passport?.name, idUploads.passport?.data, idUploads.passport?.type
            ];

            await client.query(idQuery, idValues);
        }

        // Insert previous employment (if not fresher)
        if (!isFresher && previousCompany && previousCompany.length > 0) {
            for (const job of previousCompany) {
                const jobQuery = `
                    INSERT INTO previous_employment (
                        employee_id, company_name, designation,
                        experience_years, start_date, end_date, location,
                        relieving_letter_filename, relieving_letter_data, relieving_letter_type,
                        experience_letter_filename, experience_letter_data, experience_letter_type
                    ) VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13)`;
                
                const jobValues = [
                    employee.id, job.companyName, job.designation,
                    job.experience, job.startDate, job.endDate, job.location,
                    job.relievingLetter?.name, job.relievingLetter?.data, job.relievingLetter?.type,
                    job.experienceLetter?.name, job.experienceLetter?.data, job.experienceLetter?.type
                ];

                await client.query(jobQuery, jobValues);
            }
        }

        // Calculate and update progress
        const progress = calculateProgress({
            ...employee,
            educational_details: educationDetails,
            bank_details: bankDetails,
            id_uploads: idUploads,
            previous_company: previousCompany,
            is_fresher: isFresher
        });

        await client.query(
            'UPDATE employees SET progress = $1 WHERE id = $2',
            [progress, employee.id]
        );

        await client.query('COMMIT');

        // Get full employee data to return
        const fullEmployee = await getEmployeeById(employee.id, client);
        res.status(201).json(fullEmployee);

    } catch (err) {
        await client.query('ROLLBACK');
        console.error('Transaction error:', err);
        next(err);
    } finally {
        client.release();
    }
});

// Helper function to get full employee data
async function getEmployeeById(id, client = pool) {
    const query = `
        SELECT 
            e.*,
            (SELECT json_agg(json_build_object(
                'id', ed.id,
                'educationType', ed.education_type,
                'institutionName', ed.institution_name,
                'branch', ed.branch,
                'passoutYear', ed.passout_year,
                'percentage', ed.percentage,
                'location', ed.location,
                'certificate', CASE WHEN ed.certificate_filename IS NOT NULL THEN 
                    json_build_object(
                        'name', ed.certificate_filename,
                        'type', ed.certificate_type
                    ) ELSE NULL END
            )) FROM education_details ed WHERE ed.employee_id = e.id) as educational_details,
            (SELECT json_build_object(
                'accountHolder', bd.account_holder_name,
                'bankName', bd.bank_name,
                'accountNumber', bd.account_number,
                'bankBranch', bd.branch,
                'ifscCode', bd.ifsc_code,
                'bankLocation', bd.location,
                'pinCode', bd.pin_code
            ) FROM bank_details bd WHERE bd.employee_id = e.id) as bank_details,
            (SELECT json_build_object(
                'panCard', CASE WHEN iu.pan_card_filename IS NOT NULL THEN 
                    json_build_object(
                        'name', iu.pan_card_filename,
                        'type', iu.pan_card_type
                    ) ELSE NULL END,
                'aadharCard', CASE WHEN iu.aadhar_card_filename IS NOT NULL THEN 
                    json_build_object(
                        'name', iu.aadhar_card_filename,
                        'type', iu.aadhar_card_type
                    ) ELSE NULL END,
                'passport', CASE WHEN iu.passport_filename IS NOT NULL THEN 
                    json_build_object(
                        'name', iu.passport_filename,
                        'type', iu.passport_type
                    ) ELSE NULL END
            ) FROM id_uploads iu WHERE iu.employee_id = e.id) as id_uploads,
            (SELECT json_agg(json_build_object(
                'id', pe.id,
                'companyName', pe.company_name,
                'designation', pe.designation,
                'experience', pe.experience_years,
                'startDate', pe.start_date,
                'endDate', pe.end_date,
                'location', pe.location,
                'relievingLetter', CASE WHEN pe.relieving_letter_filename IS NOT NULL THEN 
                    json_build_object(
                        'name', pe.relieving_letter_filename,
                        'type', pe.relieving_letter_type
                    ) ELSE NULL END,
                'experienceLetter', CASE WHEN pe.experience_letter_filename IS NOT NULL THEN 
                    json_build_object(
                        'name', pe.experience_letter_filename,
                        'type', pe.experience_letter_type
                    ) ELSE NULL END
            )) FROM previous_employment pe WHERE pe.employee_id = e.id) as previous_company
        FROM employees e
        WHERE e.id = $1`;
    
    const result = await client.query(query, [id]);
    return result.rows[0];
}

// Get all employees
app.get('/api/employees', async (req, res, next) => {
    try {
        const query = `
            SELECT 
                e.*,
                (SELECT COUNT(*) FROM education_details ed WHERE ed.employee_id = e.id) as education_count,
                (SELECT COUNT(*) FROM previous_employment pe WHERE pe.employee_id = e.id) as employment_count
            FROM employees e
            ORDER BY e.created_at DESC`;
        
        const result = await pool.query(query);
        res.json(result.rows);
    } catch (err) {
        console.error('Error fetching employees:', err);
        next(err);
    }
});

// Get employee by ID
app.get('/api/employees/:id', async (req, res, next) => {
    try {
        const employee = await getEmployeeById(req.params.id);
        if (!employee) {
            return res.status(404).json({ error: 'Employee not found' });
        }
        res.json(employee);
    } catch (err) {
        console.error('Error fetching employee:', err);
        next(err);
    }
});

// Update employee
app.put('/api/employees/:id', async (req, res, next) => {
    const client = await pool.connect();
    try {
        await client.query('BEGIN');
        
        const { id } = req.params;
        const {
            firstName, lastName, email, phone,
            guardianName, guardianPhone, dateOfBirth,
            gender, maritalStatus, isFresher,
            educationDetails, bankDetails, idUploads, previousCompany
        } = req.body;

        // Update employee
        const updateQuery = `
            UPDATE employees SET
                first_name = $1,
                last_name = $2,
                email = $3,
                phone = $4,
                guardian_name = $5,
                guardian_phone = $6,
                date_of_birth = $7,
                gender = $8,
                marital_status = $9,
                is_fresher = $10,
                updated_at = CURRENT_TIMESTAMP
            WHERE id = $11
            RETURNING *`;
        
        const updateValues = [
            firstName, lastName, email, phone,
            guardianName, guardianPhone, dateOfBirth,
            gender, maritalStatus, isFresher,
            id
        ];

        await client.query(updateQuery, updateValues);

        // Delete and re-insert related records for simplicity
        await client.query('DELETE FROM education_details WHERE employee_id = $1', [id]);
        await client.query('DELETE FROM bank_details WHERE employee_id = $1', [id]);
        await client.query('DELETE FROM id_uploads WHERE employee_id = $1', [id]);
        await client.query('DELETE FROM previous_employment WHERE employee_id = $1', [id]);

        // Re-insert all related data (similar to POST)
        if (educationDetails && educationDetails.length > 0) {
            for (const edu of educationDetails) {
                await client.query(
                    'INSERT INTO education_details (employee_id, education_type, institution_name, branch, passout_year, percentage, location) VALUES ($1, $2, $3, $4, $5, $6, $7)',
                    [id, edu.educationType, edu.institutionName, edu.branch, edu.passoutYear, edu.percentage, edu.location]
                );
            }
        }

        if (bankDetails) {
            await client.query(
                'INSERT INTO bank_details (employee_id, account_holder_name, bank_name, account_number, branch, ifsc_code, location, pin_code) VALUES ($1, $2, $3, $4, $5, $6, $7, $8)',
                [id, bankDetails.accountHolder, bankDetails.bankName, bankDetails.accountNumber, bankDetails.bankBranch, bankDetails.ifscCode, bankDetails.bankLocation, bankDetails.pinCode]
            );
        }

        if (idUploads) {
            await client.query(
                'INSERT INTO id_uploads (employee_id, pan_card_filename, pan_card_data, pan_card_type, aadhar_card_filename, aadhar_card_data, aadhar_card_type, passport_filename, passport_data, passport_type) VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10)',
                [id, 
                 idUploads.panCard?.name, idUploads.panCard?.data, idUploads.panCard?.type,
                 idUploads.aadharCard?.name, idUploads.aadharCard?.data, idUploads.aadharCard?.type,
                 idUploads.passport?.name, idUploads.passport?.data, idUploads.passport?.type]
            );
        }

        if (!isFresher && previousCompany && previousCompany.length > 0) {
            for (const job of previousCompany) {
                await client.query(
                    'INSERT INTO previous_employment (employee_id, company_name, designation, experience_years, start_date, end_date, location, relieving_letter_filename, relieving_letter_data, relieving_letter_type, experience_letter_filename, experience_letter_data, experience_letter_type) VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13)',
                    [id, job.companyName, job.designation, job.experience, job.startDate, job.endDate, job.location,
                     job.relievingLetter?.name, job.relievingLetter?.data, job.relievingLetter?.type,
                     job.experienceLetter?.name, job.experienceLetter?.data, job.experienceLetter?.type]
                );
            }
        }

        // Update progress
        const progress = calculateProgress({
            ...req.body,
            id,
            educational_details: educationDetails,
            bank_details: bankDetails,
            id_uploads: idUploads,
            previous_company: previousCompany,
            is_fresher: isFresher
        });

        await client.query(
            'UPDATE employees SET progress = $1 WHERE id = $2',
            [progress, id]
        );

        await client.query('COMMIT');

        const updatedEmployee = await getEmployeeById(id, client);
        res.json(updatedEmployee);

    } catch (err) {
        await client.query('ROLLBACK');
        console.error('Error updating employee:', err);
        next(err);
    } finally {
        client.release();
    }
});

// Delete employee
app.delete('/api/employees/:id', async (req, res, next) => {
    const client = await pool.connect();
    try {
        await client.query('BEGIN');
        
        const { id } = req.params;

        // Delete related records first due to foreign key constraints
        await client.query('DELETE FROM education_details WHERE employee_id = $1', [id]);
        await client.query('DELETE FROM previous_employment WHERE employee_id = $1', [id]);
        await client.query('DELETE FROM bank_details WHERE employee_id = $1', [id]);
        await client.query('DELETE FROM id_uploads WHERE employee_id = $1', [id]);

        // Delete employee
        const result = await client.query('DELETE FROM employees WHERE id = $1 RETURNING *', [id]);
        
        if (result.rowCount === 0) {
            await client.query('ROLLBACK');
            return res.status(404).json({ error: 'Employee not found' });
        }

        await client.query('COMMIT');
        res.status(204).end();

    } catch (err) {
        await client.query('ROLLBACK');
        console.error('Error deleting employee:', err);
        next(err);
    } finally {
        client.release();
    }
});

// Search employees
app.get('/api/employees/search', async (req, res, next) => {
    try {
        const { query } = req.query;
        if (!query || query.trim().length < 2) {
            return res.status(400).json({ error: 'Search query must be at least 2 characters' });
        }

        const searchQuery = `
            SELECT 
                e.id,
                e.first_name,
                e.last_name,
                e.email,
                e.phone,
                e.progress
            FROM employees e
            WHERE 
                e.first_name ILIKE $1 OR
                e.last_name ILIKE $1 OR
                e.email ILIKE $1 OR
                e.phone ILIKE $1
            ORDER BY e.first_name, e.last_name`;
        
        const result = await pool.query(searchQuery, [`%${query}%`]);
        res.json(result.rows);

    } catch (err) {
        console.error('Error searching employees:', err);
        next(err);
    }
});

// Error handling middleware
app.use(errorHandler);

// Start server
app.listen(port, () => {
    console.log(`Server running on port ${port}`);
    console.log(`PostgreSQL connected to ${process.env.DB_HOST}:${process.env.DB_PORT}`);
});
